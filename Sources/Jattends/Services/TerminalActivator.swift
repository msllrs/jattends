import AppKit

enum TerminalActivator {
    /// Map of TERM_PROGRAM values to macOS application names.
    private static let appNameMap: [String: String] = [
        "ghostty": "Ghostty",
        "Apple_Terminal": "Terminal",
        "iTerm.app": "iTerm2",
        "iTerm2": "iTerm2",
        "kitty": "kitty",
        "WarpTerminal": "Warp",
        "Alacritty": "Alacritty",
        "WezTerm": "WezTerm",
        "Hyper": "Hyper",
        "vscode": "Code",
        "tmux": "Ghostty", // tmux inherits parent; default to common host
    ]

    /// Activate the terminal window for a session.
    /// Always tries AppleScript window-matching first (matches by project name or cwd in
    /// the window title), since PID-based activation can't distinguish between windows
    /// when all windows share a single process (e.g. Ghostty).
    /// Falls back to PID-based activation only if AppleScript doesn't find a match.
    static func activate(session: SessionInfo) {
        let appName = resolveAppName(session.terminalApp)

        // Try AppleScript window-matching first — matches by project name or cwd path
        if activateByWindowTitle(appName: appName, session: session) {
            return
        }

        // Last resort: bring the app forward by PID (right app, maybe wrong window)
        if let pid = session.terminalPid {
            activateByPID(pid)
        }
    }

    private static func resolveAppName(_ termProgram: String?) -> String {
        guard let term = termProgram else { return "Terminal" }
        return appNameMap[term] ?? term
    }

    @discardableResult
    private static func activateByPID(_ pid: Int) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else {
            return false
        }
        return app.activate()
    }

    /// Use AppleScript to find a window whose title contains the project name or cwd,
    /// raise it, and activate the app. Returns true if a matching window was found.
    private static func activateByWindowTitle(appName: String, session: SessionInfo) -> Bool {
        let projectName = session.projectName
        let cwdPath = session.cwd

        // Build match candidates — project name first, then full cwd path as fallback
        // AppleScript: try each candidate, raise the first matching window
        let script = """
        tell application "System Events"
            if not (exists process "\(appName)") then return "no_process"
            tell process "\(appName)"
                set windowList to every window
                -- Try matching by project name first
                repeat with w in windowList
                    if name of w contains "\(projectName)" then
                        perform action "AXRaise" of w
                        set frontmost to true
                        tell application "\(appName)" to activate
                        return "found"
                    end if
                end repeat
                -- Try matching by cwd path
                repeat with w in windowList
                    if name of w contains "\(cwdPath)" then
                        perform action "AXRaise" of w
                        set frontmost to true
                        tell application "\(appName)" to activate
                        return "found"
                    end if
                end repeat
            end tell
        end tell
        return "not_found"
        """

        guard let appleScript = NSAppleScript(source: script) else { return false }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        return result.stringValue == "found"
    }
}
