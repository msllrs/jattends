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
    /// Uses the Accessibility API to find a window whose AXDocument matches the session's cwd,
    /// falling back to AXTitle matching, then PID-based app activation as last resort.
    static func activate(session: SessionInfo) {
        // Try AX-based window matching (AXDocument, then AXTitle)
        if let pid = session.terminalPid, activateByAX(pid: pid, session: session) {
            return
        }

        // Fallback: try by app name with AppleScript title matching
        let appName = resolveAppName(session.terminalApp)
        if activateByAppleScript(appName: appName, session: session) {
            return
        }

        // Last resort: just bring the app forward
        if let pid = session.terminalPid {
            activateByPID(pid)
        }
    }

    private static func resolveAppName(_ termProgram: String?) -> String {
        guard let term = termProgram else { return "Terminal" }
        return appNameMap[term] ?? term
    }

    // MARK: - Accessibility API approach

    /// Find and raise a window matching the session's cwd using the Accessibility API.
    /// Checks AXDocument (file URL of the working directory) and AXTitle as fallback.
    private static func activateByAX(pid: Int, session: SessionInfo) -> Bool {
        let appElement = AXUIElementCreateApplication(pid_t(pid))

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else { return false }

        let projectName = session.projectName

        // First pass: match by AXDocument (most reliable — exact cwd match)
        for window in windows {
            if let doc = axStringAttribute(window, kAXDocumentAttribute), doc.contains(session.cwd) {
                return raiseWindowAndActivate(window: window, pid: pid)
            }
        }

        // Second pass: match by AXTitle containing the project name
        for window in windows {
            if let title = axStringAttribute(window, kAXTitleAttribute), title.contains(projectName) {
                return raiseWindowAndActivate(window: window, pid: pid)
            }
        }

        // Third pass: match by AXTitle containing the cwd path
        for window in windows {
            if let title = axStringAttribute(window, kAXTitleAttribute), title.contains(session.cwd) {
                return raiseWindowAndActivate(window: window, pid: pid)
            }
        }

        return false
    }

    private static func axStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func raiseWindowAndActivate(window: AXUIElement, pid: Int) -> Bool {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            app.activate()
        }
        return true
    }

    // MARK: - PID fallback

    @discardableResult
    private static func activateByPID(_ pid: Int) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { return false }
        return app.activate()
    }

    // MARK: - AppleScript fallback (for terminals without AXDocument support)

    private static func activateByAppleScript(appName: String, session: SessionInfo) -> Bool {
        let projectName = session.projectName
        let cwdPath = session.cwd

        let script = """
        tell application "System Events"
            if not (exists process "\(appName)") then return "no_process"
            tell process "\(appName)"
                set windowList to every window
                repeat with w in windowList
                    if name of w contains "\(projectName)" then
                        perform action "AXRaise" of w
                        set frontmost to true
                        tell application "\(appName)" to activate
                        return "found"
                    end if
                end repeat
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
