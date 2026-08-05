import Foundation

/// Drives `~/.claude/scripts/awake-until-claude-idle.sh` from the menu:
/// the script keeps the Mac awake (even lid-closed) until every Claude
/// session has been quiet for a while, then restores normal sleep and
/// sleeps the Mac. It needs root for pmset, so start/stop run through
/// the macOS administrator-password prompt via osascript.
final class KeepAwakeController {
    static let shared = KeepAwakeController()

    enum Outcome: Equatable {
        case started, stopped, failed
    }

    /// Reports what actually happened after the password dialog resolves.
    var onOutcome: ((Outcome) -> Void)?

    /// True while the admin-password dialog is up (or osascript is still
    /// running) — `toggle()` is a no-op then, so a second menu click can't
    /// launch a second instance of the script.
    private(set) var actionInFlight = false

    // Seams for tests; default to the real pgrep/osascript implementations.
    var findPids: () -> [Int32] = KeepAwakeController.runningPids
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
        let pids = findPids()
        let starting = pids.isEmpty
        let command = starting
            ? Self.startCommand(scriptPath: Self.scriptPath, user: NSUserName())
            : Self.stopCommand(pids: pids)
        actionInFlight = true
        runPrivileged(command) { [weak self] ok in
            guard let self else { return }
            self.actionInFlight = false
            self.onOutcome?(ok ? (starting ? .started : .stopped) : .failed)
        }
    }

    /// osascript's `do shell script … with administrator privileges` runs
    /// as root with no SUDO_USER, and the script resolves its projects dir
    /// from SUDO_USER — unset it would watch root's empty ~/.claude and
    /// sleep the Mac immediately. Inject the real user explicitly.
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
