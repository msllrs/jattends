import XCTest
@testable import Jattends

/// Bug: activation writes an OSC 2 marker to the session's tty, then
/// "restores" an empty title — wiping the title Claude Code set (its session
/// name). The fix snapshots titles before marking and restores the marked
/// surface/window's previous title instead.
final class TitleRestoreTests: XCTestCase {
    /// Ghostty snapshot script output: one "id<TAB>name" line per surface.
    func testParsesGhosttyTitleSnapshot() {
        let out = "AAA-1\t✳ fix scroll overlay\nBBB-2\tzsh\nCCC-3\t\n"
        XCTAssertEqual(TerminalActivator.parseGhosttyTitles(out), [
            "AAA-1": "✳ fix scroll overlay",
            "BBB-2": "zsh",
            "CCC-3": "",
        ])
        XCTAssertEqual(TerminalActivator.parseGhosttyTitles(""), [:])
    }

    func testGhosttySnapshotScriptListsIdAndName() {
        let src = TerminalActivator.ghosttyTitleSnapshotScriptSource()
        XCTAssertTrue(src.hasPrefix("tell application \"Ghostty\""))
        XCTAssertTrue(src.contains("id of"))
        XCTAssertTrue(src.contains("name of"))
    }

    /// The marker focus script must report WHICH surface it focused, so the
    /// right previous title can be restored.
    func testGhosttyMarkerFocusScriptReturnsSurfaceId() {
        let src = TerminalActivator.ghosttyMarkerFocusScriptSource(marker: "__jattends_abc__")
        XCTAssertTrue(src.hasPrefix("tell application \"Ghostty\""))
        XCTAssertTrue(src.contains("name contains \"__jattends_abc__\""))
        XCTAssertTrue(src.contains("focus"))
        XCTAssertTrue(src.contains("return id of"))
        XCTAssertTrue(src.contains("return \"not_found\""))
    }

    func testTitleToRestorePrefersSnapshot() {
        let snap = ["AAA-1": "✳ fix scroll overlay", "BBB-2": "zsh"]
        XCTAssertEqual(TerminalActivator.titleToRestore(previous: snap, markedKey: "AAA-1"),
                       "✳ fix scroll overlay")
        // Unknown surface (opened mid-click) or no match: old behaviour
        XCTAssertEqual(TerminalActivator.titleToRestore(previous: snap, markedKey: "ZZZ"), "")
        XCTAssertEqual(TerminalActivator.titleToRestore(previous: snap, markedKey: nil), "")
        // A snapshot that already shows a stale marker must not be restored
        XCTAssertEqual(TerminalActivator.titleToRestore(
            previous: ["A": "__jattends_deadbeef__"], markedKey: "A"), "")
    }

    /// Restored titles go back through OSC 2 — control characters in them
    /// (BEL/ESC) would terminate the sequence early or inject escapes.
    func testTitleSequenceStripsControlCharacters() {
        XCTAssertEqual(TerminalActivator.titleSequence("✳ fix scroll"), "\u{1B}]2;✳ fix scroll\u{07}")
        XCTAssertEqual(TerminalActivator.titleSequence("a\u{07}b\u{1B}]0;evil\u{07}"),
                       "\u{1B}]2;ab]0;evil\u{07}")
        XCTAssertEqual(TerminalActivator.titleSequence(""), "\u{1B}]2;\u{07}")
    }
}
