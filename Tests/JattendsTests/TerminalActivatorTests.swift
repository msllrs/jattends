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

    /// The cross-app window search must only ever touch terminal apps.
    func testWindowSearchAppsAreTheMappedTerminals() {
        XCTAssertTrue(TerminalActivator.knownTerminalAppNames.contains("Ghostty"))
        XCTAssertTrue(TerminalActivator.knownTerminalAppNames.contains("iTerm2"))
        XCTAssertFalse(TerminalActivator.knownTerminalAppNames.contains("Finder"))
    }
}
