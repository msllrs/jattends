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
        let completion: (Bool) -> Void = { [weak self] ok in
            guard let self else { return }
            self.actionInFlight = false
            self.onOutcome?(ok ? (start ? .started : .stopped) : .failed)
        }
        if runPasswordless(start, completion) { return }
        let command = start
            ? Self.startCommand(scriptPath: Self.scriptPath, user: NSUserName())
            : Self.stopCommand(pids: findPids())
        runPrivileged(command, completion)
    }

    /// osascript's `do shell script … with administrator privileges` runs
    /// as root with no SUDO_USER, and the script resolves its projects dir
    /// from SUDO_USER — unset it would watch root's empty ~/.claude and
    /// sleep the Mac immediately. Inject the real user explicitly. (The
    /// passwordless path doesn't need this: sudo itself sets SUDO_USER.)
    static func startCommand(scriptPath: String, user: String) -> String {
        "SUDO_USER='\(user)' nohup '\(scriptPath)' >/dev/null 2>&1 &"
    }

    /// TERM (not KILL) so the script's trap restores normal sleep.
    static func stopCommand(pids: [Int32]) -> String {
        "kill -TERM " + pids.map(String.init).joined(separator: " ")
    }

    /// The script runs as root, so a plain `pgrep -f <path>` from the app
    /// still sees it (pgrep matches all users' processes by default).
    private static func runningPids() -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", scriptPath]
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
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
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
            guard passwordlessAllowed(["/usr/bin/pkill", "-TERM", "-f", script]) else { return false }
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                process.arguments = ["-n", "/usr/bin/pkill", "-TERM", "-f", script]
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
