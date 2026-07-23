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
}
