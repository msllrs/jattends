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

    /// The cross-app window search must only ever touch terminal apps.
    func testWindowSearchAppsAreTheMappedTerminals() {
        XCTAssertTrue(TerminalActivator.knownTerminalAppNames.contains("Ghostty"))
        XCTAssertTrue(TerminalActivator.knownTerminalAppNames.contains("iTerm2"))
        XCTAssertFalse(TerminalActivator.knownTerminalAppNames.contains("Finder"))
    }
}
