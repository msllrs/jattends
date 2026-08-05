import Foundation

/// Drives `~/.claude/scripts/awake-until-claude-idle.sh` from the menu:
/// the script keeps the Mac awake (even lid-closed) until every Claude
/// session has been quiet for a while, then restores normal sleep and
/// sleeps the Mac. It needs root for pmset, so start/stop run through
/// the macOS administrator-password prompt via osascript.
enum KeepAwakeController {
    static var scriptPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/scripts/awake-until-claude-idle.sh").path
    }

    /// The menu row only appears when the script is actually installed.
    static var scriptExists: Bool {
        FileManager.default.isExecutableFile(atPath: scriptPath)
    }

    static var isRunning: Bool { !runningPids().isEmpty }

    static func toggle() {
        let pids = runningPids()
        if pids.isEmpty {
            runPrivileged(startCommand(scriptPath: scriptPath, user: NSUserName()))
        } else {
            runPrivileged(stopCommand(pids: pids))
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

    private static func runPrivileged(_ command: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let escaped = command
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }
}
