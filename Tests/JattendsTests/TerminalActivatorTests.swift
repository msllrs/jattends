import XCTest
@testable import Jattends

final class TerminalActivatorTests: XCTestCase {
    /// Sessions written by --scan discovery and the statusline bridge carry
    /// terminalApp "unknown". Targeting that name with AppleScript makes
    /// macOS open a "Choose Application — Where is unknown?" dialog.
    func testUnknownTerminalAppHasNoAppleScriptTarget() {
        XCTAssertNil(TerminalActivator.appleScriptTarget("unknown"))
        XCTAssertNil(TerminalActivator.appleScriptTarget(nil))
    }

    /// An unrecognized-but-real TERM_PROGRAM value is also not safe to hand
    /// to AppleScript — only names we can map to an actual app are.
    func testUnmappedTerminalAppHasNoAppleScriptTarget() {
        XCTAssertNil(TerminalActivator.appleScriptTarget("SomeFutureTerm"))
    }

    func testKnownTerminalAppsResolve() {
        XCTAssertEqual(TerminalActivator.appleScriptTarget("ghostty"), "Ghostty")
        XCTAssertEqual(TerminalActivator.appleScriptTarget("Apple_Terminal"), "Terminal")
        XCTAssertEqual(TerminalActivator.appleScriptTarget("iTerm2"), "iTerm2")
    }

    /// Agent-feature sessions have no terminal in their process ancestry —
    /// the window that displays them can only be found by its title. The
    /// session name is the most specific needle (statusline-set titles carry
    /// it); the project folder name is the fallback.
    func testTitleMatchNeedlesPreferSessionName() {
        let labeled = SessionInfo(sessionId: "x", cwd: "/tmp/wt", status: .idle,
                                  sessionName: "orange nudge simplification")
        XCTAssertEqual(TerminalActivator.titleMatchNeedles(for: labeled),
                       ["orange nudge simplification", "wt"])

        let plain = SessionInfo(sessionId: "y", cwd: "/tmp/proj", status: .idle)
        XCTAssertEqual(TerminalActivator.titleMatchNeedles(for: plain), ["proj"])
    }

    /// When a task gets backgrounded, Claude Code leaves a "waiting room"
    /// task-list view in its terminal tab, titled with the cwd path — which
    /// contains the project name for every session in that project. The AX
    /// pass must prefer the window carrying the session name (even if it's
    /// minimized) over a path-titled window that merely matches the project.
    func testSelectWindowPrefersSessionNameOverPathTitledWaitingRoom() {
        let session = SessionInfo(sessionId: "s1", cwd: "/Users/me/git/lovable",
                                  status: .waiting, sessionName: "do we do…",
                                  terminalPid: 3139)
        let titles = ["/Users/me/git/lovable", // waiting-room view
                      "do we do…"]             // the session's real window
        XCTAssertEqual(TerminalActivator.selectWindowIndex(titles: titles, for: session), 1)
    }

    /// Without a session name the project folder name is the best needle;
    /// the cwd path is the last resort.
    func testSelectWindowFallsBackToProjectThenCwd() {
        let plain = SessionInfo(sessionId: "s2", cwd: "/Users/me/git/lovable", status: .idle)
        XCTAssertEqual(TerminalActivator.selectWindowIndex(
            titles: ["unrelated", "lovable — zsh"], for: plain), 1)
        XCTAssertEqual(TerminalActivator.selectWindowIndex(
            titles: ["unrelated", "/Users/me/git/lovable"], for: plain), 1)
        XCTAssertNil(TerminalActivator.selectWindowIndex(
            titles: ["unrelated", "other"], for: plain))
    }

    /// Ghostty splits: the needle-based pass may only run for sessions that
    /// live in Ghostty or have no known terminal (agent sessions) — a
    /// session in iTerm2 must not focus Ghostty on a title coincidence.
    func testGhosttyNeedlePassGating() {
        func session(_ app: String?) -> SessionInfo {
            SessionInfo(sessionId: "s", cwd: "/tmp/p", status: .idle, terminalApp: app)
        }
        XCTAssertTrue(TerminalActivator.ghosttyNeedlePassAllowed(for: session("ghostty")))
        XCTAssertTrue(TerminalActivator.ghosttyNeedlePassAllowed(for: session(nil)))
        XCTAssertTrue(TerminalActivator.ghosttyNeedlePassAllowed(for: session("unknown")))
        XCTAssertFalse(TerminalActivator.ghosttyNeedlePassAllowed(for: session("iTerm2")))
        XCTAssertFalse(TerminalActivator.ghosttyNeedlePassAllowed(for: session("Apple_Terminal")))
    }

    /// Needles and paths are interpolated into AppleScript string literals —
    /// quotes and backslashes must be escaped or the script won't compile
    /// (or worse, a session name could inject script).
    func testAppleScriptQuotingEscapesQuotesAndBackslashes() {
        XCTAssertEqual(TerminalActivator.appleScriptQuoted(#"say "hi" \now"#),
                       #""say \"hi\" \\now""#)
        XCTAssertEqual(TerminalActivator.appleScriptQuoted("plain"), "\"plain\"")
    }

    /// The focus script tries needles in order (most specific first), falls
    /// back to the working directory, and reports not_found so a miss can
    /// fall through to the next activation strategy.
    func testGhosttyFocusScriptStructure() {
        let src = TerminalActivator.ghosttyFocusScriptSource(
            needles: ["fix scroll", "proj"], cwd: "/tmp/proj")
        XCTAssertTrue(src.hasPrefix("tell application \"Ghostty\""))
        XCTAssertTrue(src.contains("name contains \"fix scroll\""))
        XCTAssertTrue(src.contains("name contains \"proj\""))
        XCTAssertTrue(src.contains("working directory is \"/tmp/proj\""))
        XCTAssertTrue(src.contains("return \"not_found\""))
        // Needle order preserved: session name attempted before project name
        let nameIdx = src.range(of: "fix scroll")!.lowerBound
        let projIdx = src.range(of: "name contains \"proj\"")!.lowerBound
        XCTAssertLessThan(nameIdx, projIdx)
        // Marker-style calls omit the cwd fallback entirely
        let markerSrc = TerminalActivator.ghosttyFocusScriptSource(needles: ["__jattends_abc__"])
        XCTAssertFalse(markerSrc.contains("working directory"))
    }

    /// tty-exact pane focus exists only for apps whose scripting API
    /// exposes ttys: iTerm2 (split panes) and Terminal.app (tabs). Everyone
    /// else — including Ghostty, which is handled by the marker pass — must
    /// return nil so no Apple event goes to an app that can't answer it.
    func testTtyFocusScriptOnlyForTtyExposingApps() {
        let iterm = TerminalActivator.ttyFocusScriptSource(appName: "iTerm2", tty: "/dev/ttys005")
        XCTAssertNotNil(iterm)
        XCTAssertTrue(iterm!.hasPrefix("tell application \"iTerm2\""))
        XCTAssertTrue(iterm!.contains("tty of s is \"/dev/ttys005\""))
        XCTAssertTrue(iterm!.contains("return \"not_found\""))

        let terminal = TerminalActivator.ttyFocusScriptSource(appName: "Terminal", tty: "/dev/ttys005")
        XCTAssertNotNil(terminal)
        XCTAssertTrue(terminal!.hasPrefix("tell application \"Terminal\""))
        XCTAssertTrue(terminal!.contains("tty of t is \"/dev/ttys005\""))

        XCTAssertNil(TerminalActivator.ttyFocusScriptSource(appName: "Ghostty", tty: "/dev/ttys005"))
        XCTAssertNil(TerminalActivator.ttyFocusScriptSource(appName: "kitty", tty: "/dev/ttys005"))
        XCTAssertNil(TerminalActivator.ttyFocusScriptSource(appName: nil, tty: "/dev/ttys005"))
    }

    /// The cross-app window search must only ever touch terminal apps.
    func testWindowSearchAppsAreTheMappedTerminals() {
        XCTAssertTrue(TerminalActivator.knownTerminalAppNames.contains("Ghostty"))
        XCTAssertTrue(TerminalActivator.knownTerminalAppNames.contains("iTerm2"))
        XCTAssertFalse(TerminalActivator.knownTerminalAppNames.contains("Finder"))
    }
}
