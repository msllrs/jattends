import Foundation

/// Drives `~/.claude/scripts/awake-until-claude-idle.sh` from the menu:
/// the script keeps the Mac awake (even lid-closed) until every Claude
/// session has been quiet for a while, then restores normal sleep and
/// sleeps the Mac. It needs root for pmset; with a sudoers rule in place
/// start/stop run silently via `sudo -n`, otherwise they fall back to the
/// macOS administrator-password prompt via osascript.
final class KeepAwakeController {
    static let shared = KeepAwakeController()

    enum Outcome: Equatable {
        case started, stopped, failed
    }

    /// Reports what actually happened after the privileged run resolves.
    var onOutcome: ((Outcome) -> Void)?

    /// True while a privileged run (or its password dialog) is pending —
    /// `toggle()` is a no-op then, so a second menu click can't launch a
    /// second instance of the script.
    private(set) var actionInFlight = false

    // Seams for tests; default to the real sudo/pgrep/osascript implementations.
    var findPids: () -> [Int32] = KeepAwakeController.runningPids
    /// Returns false WITHOUT calling the completion when no sudoers rule
    /// allows the action passwordless; the caller then falls back to the
    /// admin-prompt path.
    var runPasswordless: (_ start: Bool, _ completion: @escaping (Bool) -> Void) -> Bool =
        KeepAwakeController.runPasswordless
    var runPrivileged: (_ command: String, _ completion: @escaping (Bool) -> Void) -> Void =
        KeepAwakeController.runPrivileged
    var awaitExit: (_ isGone: @escaping () -> Bool, _ done: @escaping () -> Void) -> Void =
        KeepAwakeController.awaitExit

    static var scriptPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/scripts/awake-until-claude-idle.sh").path
    }

    /// The menu row only appears when the script is actually installed.
    static var scriptExists: Bool {
        FileManager.default.isExecutableFile(atPath: scriptPath)
    }

    var isRunning: Bool { !findPids().isEmpty }

    func toggle() {
        guard !actionInFlight else { return }
        perform(start: findPids().isEmpty)
    }

    /// The notification's Stop action fires blind — the script may have
    /// died in the meantime, so only act when something is running.
    func stop() {
        guard !actionInFlight, !findPids().isEmpty else { return }
        perform(start: false)
    }

    private func perform(start: Bool) {
        actionInFlight = true
        let finish: (Outcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            // A TERM'd script spends a couple of seconds in its cleanup
            // trap (restore_sleep + pmset) and pgrep still sees it — keep
            // the row busy until the process is actually gone, or the menu
            // shows a live row for a dying process. Outcome still reports
            // promptly; only the busy flag waits.
            if outcome == .stopped {
                self.onOutcome?(outcome)
                self.awaitExit(
                    { [weak self] in self?.findPids().isEmpty ?? true },
                    { [weak self] in self?.actionInFlight = false }
                )
            } else {
                self.actionInFlight = false
                self.onOutcome?(outcome)
            }
        }
        // Passwordless spawns the Process directly and fails loudly on
        // spawn errors, so its result is trusted as-is (it also completes
        // before pgrep would see the fresh process).
        if runPasswordless(start, { ok in
            finish(ok ? (start ? .started : .stopped) : .failed)
        }) { return }
        let command = start
            ? Self.startCommand(scriptPath: Self.scriptPath, user: NSUserName(), logPath: Self.logPath)
            : Self.stopCommand(pids: findPids())
        runPrivileged(command) { [weak self] ok in
            guard let self else { return }
            // Prompt-path starts need verification: the trampoline shell
            // exits 0 even when the backgrounded launch died immediately
            // (nohup's console error hid every failure this way), so only
            // report .started if the script process actually exists now.
            if start {
                finish(ok && !self.findPids().isEmpty ? .started : .failed)
            } else {
                finish(ok ? .stopped : .failed)
            }
        }
    }

    /// The script's stdout narrates its lifecycle (sleep disabled, idle
    /// reached, TERM cleanup) — kept in a log so a dead instance can be
    /// diagnosed after the fact.
    static var logPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/jattends/keepawake.log").path
    }

    /// osascript's `do shell script … with administrator privileges` runs
    /// as root with no SUDO_USER, and the script resolves its projects dir
    /// from SUDO_USER — unset it would watch root's empty ~/.claude and
    /// sleep the Mac immediately. Inject the real user explicitly. (The
    /// passwordless path doesn't need this: sudo itself sets SUDO_USER.)
    ///
    /// No nohup: under security_authtrampoline it dies with "can't detach
    /// from console: Inappropriate ioctl for device" BEFORE launching the
    /// script, and the backgrounding `&` still made the shell exit 0 — the
    /// launch was silently swallowed. Detach the TN2065 way instead:
    /// backgrounded with all three stdio streams redirected.
    static func startCommand(scriptPath: String, user: String, logPath: String) -> String {
        "date '+--- start %F %T' >>'\(logPath)'; SUDO_USER='\(user)' '\(scriptPath)' >>'\(logPath)' 2>&1 </dev/null &"
    }

    /// TERM (not KILL) so the script's trap restores normal sleep.
    static func stopCommand(pids: [Int32]) -> String {
        "kill -TERM " + pids.map(String.init).joined(separator: " ")
    }

    /// `pgrep -f` on the bare path is a substring match — any process
    /// merely mentioning the path in its argv (editors, watcher shells)
    /// would count as running and later get TERMed. Anchor to the actual
    /// interpreter invocation instead; no trailing anchor because the
    /// script may be run with an idle-seconds argument.
    static func processPattern(scriptPath: String) -> String {
        "^/bin/zsh " + scriptPath.replacingOccurrences(of: ".", with: "\\.")
    }

    /// `-u root`: the script always runs as root, so a user-owned process
    /// must never count (or be killed by the pid-based stop path).
    private static func runningPids() -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-u", "root", "-f", processPattern(scriptPath: scriptPath)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
    }

    /// Keeps detached sudo Processes alive until they exit — deallocating
    /// a running Process kills the child, and the start script runs for hours.
    private static var detachedProcesses: [Process] = []

    private static func logHandle() -> FileHandle {
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: logPath) else {
            return FileHandle.nullDevice
        }
        handle.seekToEndOfFile()
        return handle
    }

    /// Polls until the stopped script is really gone: every 250ms on the
    /// main queue, capped at 20 attempts (~5s) so a kill that somehow
    /// failed can't wedge the menu row in the busy state forever.
    private static func awaitExit(isGone: @escaping () -> Bool, done: @escaping () -> Void) {
        func poll(_ attemptsLeft: Int) {
            if isGone() || attemptsLeft <= 0 {
                done()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                poll(attemptsLeft - 1)
            }
        }
        poll(20)
    }

    /// `sudo -n -l <cmd…>` exits 0 iff a sudoers rule allows running the
    /// command without a password.
    private static func passwordlessAllowed(_ command: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "-l"] + command
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Completions are delivered on the main queue so app wiring can touch
    /// UI state.
    private static func runPasswordless(start: Bool, completion: @escaping (Bool) -> Void) -> Bool {
        let script = scriptPath
        if start {
            guard passwordlessAllowed([script]) else { return false }
            // Detached: the script runs until Claude sessions idle, so
            // don't wait for exit — launch and report that it started.
            // sudo sets SUDO_USER itself on this path.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", script]
            process.standardInput = FileHandle.nullDevice
            let log = logHandle()
            process.standardOutput = log
            process.standardError = log
            process.terminationHandler = { finished in
                DispatchQueue.main.async {
                    detachedProcesses.removeAll { $0 === finished }
                }
            }
            do { try process.run() } catch {
                DispatchQueue.main.async { completion(false) }
                return true
            }
            detachedProcesses.append(process)
            DispatchQueue.main.async { completion(true) }
        } else {
            // The -l check and the run must share the exact argument
            // vector for a sudoers rule to cover both.
            let pkill = ["/usr/bin/pkill", "-TERM", "-f", processPattern(scriptPath: script)]
            guard passwordlessAllowed(pkill) else { return false }
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                process.arguments = ["-n"] + pkill
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                process.waitUntilExit()
                let ok = process.terminationStatus == 0
                DispatchQueue.main.async { completion(ok) }
            }
        }
        return true
    }

    /// Completion (exit 0 → true) is delivered on the main queue so app
    /// wiring can touch UI state; osascript exits non-zero when the user
    /// cancels the password dialog.
    private static func runPrivileged(_ command: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let escaped = command
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch {
                DispatchQueue.main.async { completion(false) }
                return
            }
            process.waitUntilExit()
            let ok = process.terminationStatus == 0
            DispatchQueue.main.async { completion(ok) }
        }
    }
}
