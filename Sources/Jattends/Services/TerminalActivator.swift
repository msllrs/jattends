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
        "rex": "Rex Beta",
        "tmux": "Ghostty", // tmux inherits parent; default to common host
    ]

    /// App names the cross-app window title search may touch — the mapped
    /// terminals only, never arbitrary running applications.
    static let knownTerminalAppNames: Set<String> = Set(appNameMap.values)

    private static var hasPromptedAccessibility = false

    /// Append a line to ~/.claude/jattends/debug.log — activation failures
    /// are otherwise invisible (menu clicks have no UI for errors).
    private static func log(_ message: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/jattends/debug.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Activate the terminal window for a session.
    /// Strategy order: OSC 2 title marker (exact window), AXDocument/AXTitle
    /// matching, AppleScript title matching, then PID-based app activation.
    static func activate(session: SessionInfo) {
        log("activate: \(session.projectName) pid=\(session.terminalPid.map(String.init) ?? "nil") tty=\(session.terminalTty ?? "nil") trusted=\(AXIsProcessTrusted())")

        // Prompt for Accessibility permission once per launch
        if !hasPromptedAccessibility && !AXIsProcessTrusted() {
            hasPromptedAccessibility = true
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }

        // Rex is a multiplexer: the session's pane is addressed by its block
        // ID via the rex CLI. Exact, and never touches the session's tty.
        if session.rexBlock != nil {
            if activateRexBlock(session: session) {
                log("  -> Rex block focused")
                return
            }
        }

        // Most precise where the app's scripting API exposes ttys directly:
        // iTerm2 split panes and Terminal.app tabs are scriptable objects
        // with a `tty` property, so the session's pane is an exact lookup —
        // no title heuristics at all.
        if activatePaneByTty(session: session) {
            log("  -> tty pane matched")
            return
        }

        // Most precise for Ghostty: its scripting dictionary (1.3+) exposes
        // every split surface with its own title and a `focus` command that
        // raises the exact split. Window titles only carry the *focused*
        // split's title, so no window-level pass can find a session sitting
        // in a background split — this one can. The unique tty marker makes
        // false positives impossible, so it's safe to try for any session.
        if activateGhosttySplitByMarker(session: session) {
            log("  -> Ghostty split marker matched")
            return
        }

        // Most precise: tag the session's tty with a unique window title via
        // OSC 2, raise the window carrying it, then restore the window's
        // previous title (snapshotted before marking). Finds
        // the exact tab even with several sessions in the same project.
        if activateByTitleMarker(session: session) {
            log("  -> title marker matched")
            return
        }

        // Try AX-based window matching (AXDocument, then AXTitle)
        if let pid = session.terminalPid, activateByAX(pid: pid, session: session) {
            log("  -> AX matched")
            return
        }

        // Agent-feature sessions have no terminal ancestry (pid/tty are nil),
        // but their window title carries the session or project name — search
        // every known terminal app's windows for it.
        if activateByTitleSearch(session: session) {
            log("  -> window title search matched")
            return
        }

        // Ghostty again, by title/cwd needles this time — for sessions whose
        // tty marker couldn't be written (agent sessions have no tty). Only
        // when the session is known to live in Ghostty or has no known
        // terminal at all; a session in another app shouldn't focus Ghostty
        // just because a surface title resembles the project name.
        if ghosttyNeedlePassAllowed(for: session), activateGhosttySplitByNeedles(session: session) {
            log("  -> Ghostty split title matched")
            return
        }

        // Fallback: try by app name with AppleScript title matching — only
        // for terminals we can map to a real app, otherwise macOS shows a
        // "Choose Application" dialog for the unknown name
        if let appName = appleScriptTarget(session.terminalApp) {
            if activateByAppleScript(appName: appName, session: session) {
                log("  -> AppleScript matched")
                return
            }
        } else {
            log("  -> AppleScript skipped (no known app)")
        }

        // Last resort: just bring the app forward
        log("  -> PID fallback")
        if let pid = session.terminalPid {
            activateByPID(pid)
        }
    }

    /// App name safe to target with AppleScript, or nil when the TERM_PROGRAM
    /// value is missing or not in the map (e.g. "unknown" from --scan).
    static func appleScriptTarget(_ terminalApp: String?) -> String? {
        guard let term = terminalApp else { return nil }
        return appNameMap[term]
    }

    /// Title substrings to look for, most specific first: the session name
    /// (statusline-set titles carry it), then the project folder name.
    static func titleMatchNeedles(for session: SessionInfo) -> [String] {
        if let name = session.sessionName, !name.isEmpty {
            return [name, session.projectName]
        }
        return [session.projectName]
    }

    /// Index of the window (by title) the AX pass should raise, or nil.
    /// Checked needle-by-needle across all titles so the most specific
    /// needle wins globally, not just per window.
    static func selectWindowIndex(titles: [String], for session: SessionInfo) -> Int? {
        for needle in titleMatchNeedles(for: session) + [session.cwd] {
            if let idx = titles.firstIndex(where: { $0.contains(needle) }) {
                return idx
            }
        }
        return nil
    }

    // MARK: - tty-exact pane focus (iTerm2 split panes, Terminal.app tabs)

    /// AppleScript that selects the pane/tab owning `tty` and raises its
    /// window, or nil for apps whose scripting API doesn't expose ttys.
    /// iTerm2 models each split pane as a `session` with a `tty` property;
    /// Terminal.app models each tab likewise (it has no splits).
    static func ttyFocusScriptSource(appName: String?, tty: String) -> String? {
        let quotedTty = appleScriptQuoted(tty)
        switch appName {
        case "iTerm2":
            return """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is \(quotedTty) then
                                select s
                                select t
                                try
                                    set miniaturized of w to false
                                end try
                                select w
                                activate
                                return "found"
                            end if
                        end repeat
                    end repeat
                end repeat
                return "not_found"
            end tell
            """
        case "Terminal":
            return """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is \(quotedTty) then
                            set selected of t to true
                            try
                                set miniaturized of w to false
                            end try
                            -- `set index of w to 1` reorders the AppleScript
                            -- list without raising the window; frontmost does
                            set frontmost of w to true
                            activate
                            return "found"
                        end if
                    end repeat
                end repeat
                return "not_found"
            end tell
            """
        default:
            return nil
        }
    }

    /// Select the exact pane/tab owning the session's tty, for terminals
    /// whose scripting API exposes ttys. Gated to the session's own app so
    /// no Apple event (and no Automation consent prompt) goes anywhere else,
    /// and to running apps so a stale session can't cold-launch a terminal.
    private static func activatePaneByTty(session: SessionInfo) -> Bool {
        guard let tty = session.terminalTty, tty.hasPrefix("/dev/"),
              let appName = appleScriptTarget(session.terminalApp),
              let source = ttyFocusScriptSource(appName: appName, tty: tty),
              isAppRunning(named: appName)
        else { return false }
        return runFocusScript(source, label: "tty pane")
    }

    // MARK: - Ghostty split focus (scripting dictionary, Ghostty 1.3+)

    /// Whether the needle-based Ghostty pass may run: the session lives in
    /// Ghostty, or its terminal is unknown (agent sessions). Sessions mapped
    /// to another app must not focus Ghostty on a coincidental title match.
    static func ghosttyNeedlePassAllowed(for session: SessionInfo) -> Bool {
        let target = appleScriptTarget(session.terminalApp)
        return target == "Ghostty" || target == nil
    }

    /// Escape a string for interpolation inside AppleScript double quotes.
    static func appleScriptQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
               .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// AppleScript that focuses the first Ghostty surface whose title
    /// contains one of the needles (tried in order), optionally falling back
    /// to a working-directory match. Each attempt is wrapped in `try`
    /// because `first terminal whose …` throws when nothing matches.
    static func ghosttyFocusScriptSource(needles: [String], cwd: String? = nil) -> String {
        var attempts = needles.map { needle in
            """
                try
                    focus (first terminal whose name contains \(appleScriptQuoted(needle)))
                    activate
                    return "found"
                end try
            """
        }
        if let cwd {
            attempts.append("""
                try
                    focus (first terminal whose working directory is \(appleScriptQuoted(cwd)))
                    activate
                    return "found"
                end try
            """)
        }
        return """
        tell application "Ghostty"
        \(attempts.joined(separator: "\n"))
            return "not_found"
        end tell
        """
    }

    /// AppleScript that lists every Ghostty surface as one "id<TAB>name"
    /// line — the titles to restore after an OSC 2 marker overwrites one.
    static func ghosttyTitleSnapshotScriptSource() -> String {
        """
        tell application "Ghostty"
            set out to {}
            repeat with t in terminals
                set end of out to ((id of t) as text) & tab & ((name of t) as text)
            end repeat
            set AppleScript's text item delimiters to linefeed
            set joined to out as text
            set AppleScript's text item delimiters to ""
            return joined
        end tell
        """
    }

    /// Parse the snapshot script's output into surface id → title. Titles
    /// may be empty; blank lines are skipped.
    static func parseGhosttyTitles(_ output: String) -> [String: String] {
        var titles: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let id = String(parts[0])
            guard !id.isEmpty else { continue }
            titles[id] = parts.count > 1 ? String(parts[1]) : ""
        }
        return titles
    }

    /// AppleScript that focuses the Ghostty surface whose title carries the
    /// marker and returns its id (so its previous title can be restored), or
    /// "not_found". Wrapped in `try` because `first terminal whose …` throws
    /// when nothing matches.
    static func ghosttyMarkerFocusScriptSource(marker: String) -> String {
        """
        tell application "Ghostty"
            try
                set t to (first terminal whose name contains \(appleScriptQuoted(marker)))
                focus t
                activate
                return id of t
            end try
            return "not_found"
        end tell
        """
    }

    private static func ghosttyIsRunning() -> Bool {
        isAppRunning(named: "Ghostty")
    }

    private static func isAppRunning(named name: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.localizedName == name }
    }

    private static func runFocusScript(_ source: String, label: String) -> Bool {
        let result = runScript(source, label: label)
        if let result, result != "found" {
            log("  \(label) script: \(result)")
        }
        return result == "found"
    }

    /// Run an AppleScript and return its string result, or nil when it fails
    /// to compile/run (errors are logged under `label`).
    private static func runScript(_ source: String, label: String) -> String? {
        guard let script = NSAppleScript(source: source) else {
            log("  \(label) script: failed to init NSAppleScript")
            return nil
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            log("  \(label) script error: \(error[NSAppleScript.errorBriefMessage] ?? error)")
            return nil
        }
        return result.stringValue ?? ""
    }

    /// Tag the session's tty with a unique title via OSC 2, then focus the
    /// Ghostty surface carrying it. Surfaces keep their own titles, so this
    /// finds the session's split even when it isn't the focused one. Every
    /// surface's title is snapshotted first, and the marked surface's
    /// previous title (e.g. Claude Code's session name) is written back.
    private static func activateGhosttySplitByMarker(session: SessionInfo) -> Bool {
        guard mayWriteTitleMarker(for: session),
              ghosttyIsRunning(),
              let tty = session.terminalTty, tty.hasPrefix("/dev/")
        else { return false }

        let snapshot = parseGhosttyTitles(
            runScript(ghosttyTitleSnapshotScriptSource(), label: "Ghostty title snapshot") ?? "")

        let marker = "__jattends_\(session.sessionId.prefix(8))__"
        guard writeToTty(tty, titleSequence(marker)) else {
            log("  Ghostty split: tty write failed for \(tty)")
            return false
        }
        var markedId: String?
        // Restore the marked surface's previous title ("" when unknown)
        defer { _ = writeToTty(tty, titleSequence(titleToRestore(previous: snapshot, markedKey: markedId))) }

        // Give Ghostty a moment to process the escape sequence
        usleep(120_000)

        let result = runScript(ghosttyMarkerFocusScriptSource(marker: marker), label: "Ghostty split")
        guard let result, !result.isEmpty, result != "not_found" else {
            log("  Ghostty split script: \(result ?? "no result")")
            return false
        }
        markedId = result
        return true
    }

    /// Focus a Ghostty surface by session-name/project-name title match or
    /// working directory — for sessions whose tty we can't tag.
    private static func activateGhosttySplitByNeedles(session: SessionInfo) -> Bool {
        guard ghosttyIsRunning() else { return false }
        return runFocusScript(ghosttyFocusScriptSource(
            needles: titleMatchNeedles(for: session), cwd: session.cwd), label: "Ghostty split")
    }

    // MARK: - Rex multiplexer (block focus via the rex CLI)

    private static let rexBundleIdentifier = "com.superlogical.rex"
    private static let rexBundledExecutable =
        "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.app/Contents/MacOS/rex"

    /// The `window: <id>` value from `rex block inspect` output, or nil
    /// for unplaced blocks.
    static func rexWindowId(fromInspect output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("window:") else { continue }
            let value = trimmed.dropFirst("window:".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The rex CLI: the bin dir the hook saw, else the app bundle's copy.
    static func rexExecutable(for session: SessionInfo) -> String {
        if let dir = session.rexBinDir, !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("rex").path
        }
        return rexBundledExecutable
    }

    /// Arguments for a click: switch Rex.app to the session/window (needs
    /// Remote Control; failure tolerated), then focus the block. Never
    /// autostart a server from a menu click.
    static func rexFocusCommands(for session: SessionInfo, windowId: String?) -> [[String]] {
        var commands: [[String]] = []
        if let rexSession = session.rexSession {
            var select = ["--autostart=false", "do", "session.select", "session_id=\(rexSession)"]
            if let windowId { select.append("window_id=\(windowId)") }
            commands.append(select)
        }
        if let block = session.rexBlock {
            commands.append(["--autostart=false", "block", "focus", block])
        }
        return commands
    }

    /// Focus the session's Rex block and bring Rex.app forward. False when
    /// the CLI is missing or the block is gone (inspect/focus failed).
    private static func activateRexBlock(session: SessionInfo) -> Bool {
        guard let block = session.rexBlock else { return false }
        let exe = rexExecutable(for: session)
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            log("  Rex: no executable at \(exe)")
            return false
        }

        let inspect = runRex(exe, ["--autostart=false", "block", "inspect", block])
        guard inspect.ok else {
            log("  Rex: block inspect failed (\(inspect.output))")
            return false
        }
        let windowId = rexWindowId(fromInspect: inspect.output)

        for args in rexFocusCommands(for: session, windowId: windowId) {
            let result = runRex(exe, args)
            if args.contains("session.select") {
                // Needs Remote Control enabled in Rex.app; focus still works
                if !result.ok { log("  Rex: session.select failed (\(result.output))") }
            } else if !result.ok {
                log("  Rex: \(args.joined(separator: " ")) failed (\(result.output))")
                return false
            }
        }

        if let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: rexBundleIdentifier).first {
            if app.isHidden { app.unhide() }
            app.activate()
        } else {
            log("  Rex: app not running")
        }
        return true
    }

    /// Run the rex CLI with a short timeout. Output is stdout+stderr,
    /// trimmed — used for parsing (inspect) and for logging failures.
    private static func runRex(_ exe: String, _ args: [String],
                               timeout: TimeInterval = 2) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return (false, "launch failed: \(error.localizedDescription)")
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 0.5)
            return (false, "timed out after \(timeout)s")
        }
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = (out + err).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus == 0, combined)
    }

    // MARK: - Cross-app window title search (for sessions without a terminal PID)

    /// Scan the windows of every running terminal app for one whose AXTitle
    /// contains a needle. Outer loop over needles so the most specific match
    /// wins globally, not just within one app.
    private static func activateByTitleSearch(session: SessionInfo) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard let name = app.localizedName else { return false }
            return knownTerminalAppNames.contains(name)
        }

        for needle in titleMatchNeedles(for: session) {
            for app in apps {
                let pid = Int(app.processIdentifier)
                let appElement = AXUIElementCreateApplication(app.processIdentifier)
                var windowsRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                      let windows = windowsRef as? [AXUIElement]
                else { continue }

                for window in windows {
                    if let title = axStringAttribute(window, kAXTitleAttribute), title.contains(needle) {
                        return raiseWindowAndActivate(window: window, pid: pid)
                    }
                }
            }
        }
        return false
    }

    // MARK: - OSC 2 title-marker approach

    /// Whether an OSC 2 marker may be written to the session's tty. The
    /// restore writes back the title snapshotted before marking, which is
    /// best-effort (a terminal that decorates window titles restores the
    /// decorated text; an unmatched surface restores an empty title) — Rex
    /// sessions are focused exactly by block ID instead, so their tty is
    /// never written to.
    static func mayWriteTitleMarker(for session: SessionInfo) -> Bool {
        session.terminalApp != "rex" && session.rexBlock == nil
    }

    /// The title to write back after marking: the marked surface/window's
    /// snapshotted title, or "" (terminal default) when it's unknown or the
    /// snapshot itself still shows a stale marker.
    static func titleToRestore<K: Hashable>(previous: [K: String], markedKey: K?) -> String {
        guard let markedKey, let title = previous[markedKey],
              !title.contains("__jattends_")
        else { return "" }
        return title
    }

    /// OSC 2 set-title sequence. C0 controls and DEL are stripped so a
    /// restored title can't end the sequence early (BEL/ESC) or inject
    /// further escapes.
    static func titleSequence(_ title: String) -> String {
        let clean = String(String.UnicodeScalarView(title.unicodeScalars.filter {
            $0.value >= 0x20 && $0.value != 0x7F
        }))
        return "\u{1B}]2;" + clean + "\u{07}"
    }

    /// Write a unique title to the session's tty, then raise the window whose
    /// AXTitle contains it. Works with any terminal that honors OSC 2 —
    /// including agent sessions, whose daemon-created pty forwards the escape
    /// to whichever terminal window displays them.
    private static func activateByTitleMarker(session: SessionInfo) -> Bool {
        guard mayWriteTitleMarker(for: session),
              AXIsProcessTrusted(),
              let tty = session.terminalTty, tty.hasPrefix("/dev/")
        else { return false }

        // Known terminal PID: scan just that app. Agent sessions have none —
        // scan every running terminal app for the marker instead.
        let candidatePids: [Int]
        if let pid = session.terminalPid {
            candidatePids = [pid]
        } else {
            candidatePids = NSWorkspace.shared.runningApplications
                .filter { app in
                    guard let name = app.localizedName else { return false }
                    return knownTerminalAppNames.contains(name)
                }
                .map { Int($0.processIdentifier) }
        }

        // Snapshot every candidate window's title BEFORE marking. The window
        // elements themselves are kept and re-read after marking, so the
        // match maps back to its own snapshot even if the windows array
        // reorders in between.
        var windows: [(key: String, pid: Int, element: AXUIElement)] = []
        var snapshot: [String: String] = [:]
        for pid in candidatePids {
            let appElement = AXUIElementCreateApplication(pid_t(pid))
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let appWindows = windowsRef as? [AXUIElement]
            else { continue }
            for (index, window) in appWindows.enumerated() {
                let key = "\(pid):\(index)"
                windows.append((key, pid, window))
                snapshot[key] = axStringAttribute(window, kAXTitleAttribute) ?? ""
            }
        }

        let marker = "__jattends_\(session.sessionId.prefix(8))__"
        guard writeToTty(tty, titleSequence(marker)) else { return false }
        var markedKey: String?
        // Restore the marked window's previous title ("" when unknown)
        defer { _ = writeToTty(tty, titleSequence(titleToRestore(previous: snapshot, markedKey: markedKey))) }

        // Give the terminal a moment to process the escape sequence
        usleep(120_000)

        for window in windows {
            if let title = axStringAttribute(window.element, kAXTitleAttribute), title.contains(marker) {
                markedKey = window.key
                return raiseWindowAndActivate(window: window.element, pid: window.pid)
            }
        }
        return false
    }

    private static func writeToTty(_ tty: String, _ text: String) -> Bool {
        let fd = open(tty, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var ok = false
        text.utf8CString.withUnsafeBufferPointer { buf in
            let count = buf.count - 1 // drop trailing NUL
            ok = write(fd, buf.baseAddress, count) == count
        }
        return ok
    }

    // MARK: - Accessibility API approach

    /// Find and raise a window matching the session's cwd using the Accessibility API.
    /// Checks AXDocument (file URL of the working directory) and AXTitle as fallback.
    private static func activateByAX(pid: Int, session: SessionInfo) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let appElement = AXUIElementCreateApplication(pid_t(pid))

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else { return false }

        // First pass: match by AXDocument (most reliable — exact cwd match)
        for window in windows {
            if let doc = axStringAttribute(window, kAXDocumentAttribute), doc.contains(session.cwd) {
                return raiseWindowAndActivate(window: window, pid: pid)
            }
        }

        // Remaining passes: match by AXTitle, most specific needle first
        let titles = windows.map { axStringAttribute($0, kAXTitleAttribute) ?? "" }
        if let idx = selectWindowIndex(titles: titles, for: session) {
            return raiseWindowAndActivate(window: windows[idx], pid: pid)
        }

        return false
    }

    private static func axStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func raiseWindowAndActivate(window: AXUIElement, pid: Int) -> Bool {
        // Restore windows minimized to the Dock and unhide the app (⌘H) —
        // raising alone leaves them invisible
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? Bool) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        }
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)), app.isHidden {
            app.unhide()
        }

        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            app.activate()
        }
        return true
    }

    // MARK: - PID fallback

    @discardableResult
    private static func activateByPID(_ pid: Int) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { return false }
        if app.isHidden {
            app.unhide()
        }
        return app.activate()
    }

    // MARK: - AppleScript fallback (for terminals without AXDocument support)

    private static func activateByAppleScript(appName: String, session: SessionInfo) -> Bool {
        let projectName = session.projectName
        let cwdPath = session.cwd

        let script = """
        tell application "\(appName)" to activate

        tell application "System Events"
            tell process "\(appName)"
                set visible to true
                set frontmost to true
                try
                    set windowList to every window
                    repeat with w in windowList
                        if name of w contains "\(projectName)" then
                            try
                                if value of attribute "AXMinimized" of w is true then
                                    set value of attribute "AXMinimized" of w to false
                                end if
                            end try
                            perform action "AXRaise" of w
                            return "found"
                        end if
                    end repeat
                    repeat with w in windowList
                        if name of w contains "\(cwdPath)" then
                            try
                                if value of attribute "AXMinimized" of w is true then
                                    set value of attribute "AXMinimized" of w to false
                                end if
                            end try
                            perform action "AXRaise" of w
                            return "found"
                        end if
                    end repeat
                end try
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
