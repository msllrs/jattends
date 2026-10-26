import XCTest
@testable import Jattends

/// Rex is a multiplexer: claude runs under the rex server daemon, so there
/// is no terminal PID, and the pane is addressed by the block ID the hook
/// records from REX_BLOCK.
final class RexActivatorTests: XCTestCase {
    private let block = "block:01a17930-e285-72f1-af70-533882e2596c"
    private let rexSession = "session:01a17930-e285-7071-9c29-96dbb57b5fff"

    private func rexSessionInfo(binDir: String? = nil) -> SessionInfo {
        SessionInfo(sessionId: "s1", cwd: "/Users/me/git/lovable", status: .waiting,
                    terminalApp: "rex", terminalTty: "/dev/ttys014",
                    rexBlock: block, rexSession: rexSession, rexBinDir: binDir)
    }

    func testSessionJSONDecodesRexFields() throws {
        let json = """
        {"sessionId":"s1","cwd":"/tmp/p","status":"waiting","terminalApp":"rex",
         "rexBlock":"\(block)","rexSession":"\(rexSession)",
         "rexBinDir":"/opt/rex/bin","updatedAt":"2026-10-26T16:24:43Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let s = try decoder.decode(SessionInfo.self, from: Data(json.utf8))
        XCTAssertEqual(s.rexBlock, block)
        XCTAssertEqual(s.rexSession, rexSession)
        XCTAssertEqual(s.rexBinDir, "/opt/rex/bin")
    }

    /// Bug: clicking a session wrote an OSC 2 marker to its tty and then
    /// "restored" an empty title, wiping the session name Claude Code had
    /// set (Rex then showed "Claude Code ~/git/lovable"). Rex sessions are
    /// focused by block ID, so nothing may ever be written to their tty.
    func testRexSessionsNeverGetTitleMarkers() {
        XCTAssertFalse(TerminalActivator.mayWriteTitleMarker(for: rexSessionInfo()))
        let byTermProgramOnly = SessionInfo(sessionId: "s2", cwd: "/tmp/p", status: .idle,
                                            terminalApp: "rex", terminalTty: "/dev/ttys003")
        XCTAssertFalse(TerminalActivator.mayWriteTitleMarker(for: byTermProgramOnly))
        let ghostty = SessionInfo(sessionId: "s3", cwd: "/tmp/p", status: .idle,
                                  terminalApp: "ghostty", terminalTty: "/dev/ttys004")
        XCTAssertTrue(TerminalActivator.mayWriteTitleMarker(for: ghostty))
    }

    /// The block's window can change (blocks move), so it's read from
    /// `rex block inspect` at click time.
    func testParsesWindowFromBlockInspect() {
        let out = """
        block: \(block)
        session: \(rexSession)
        label: shell
        placement: placed
        window: window:01a17930-e29b-77a5-9e91-6a38bb3fde22
        methods: 13
        """
        XCTAssertEqual(TerminalActivator.rexWindowId(fromInspect: out),
                       "window:01a17930-e29b-77a5-9e91-6a38bb3fde22")
        XCTAssertNil(TerminalActivator.rexWindowId(fromInspect: "block: x\nplacement: unplaced\n"))
    }

    /// Prefer the bin dir the hook saw; fall back to the app bundle's CLI.
    func testRexExecutableResolution() {
        XCTAssertEqual(TerminalActivator.rexExecutable(for: rexSessionInfo(binDir: "/opt/rex/bin")),
                       "/opt/rex/bin/rex")
        XCTAssertEqual(TerminalActivator.rexExecutable(for: rexSessionInfo()),
                       "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.app/Contents/MacOS/rex")
    }

    /// Commands for a click: switch Rex.app to the session/window (needs
    /// Remote Control; failure is tolerated), then focus the block. Never
    /// autostart a server from a menu click.
    func testRexFocusCommands() {
        let cmds = TerminalActivator.rexFocusCommands(
            for: rexSessionInfo(), windowId: "window:w1")
        XCTAssertEqual(cmds, [
            ["--autostart=false", "do", "session.select",
             "session_id=\(rexSession)", "window_id=window:w1"],
            ["--autostart=false", "block", "focus", block],
        ])
        let noWindow = TerminalActivator.rexFocusCommands(for: rexSessionInfo(), windowId: nil)
        XCTAssertEqual(noWindow.first, ["--autostart=false", "do", "session.select",
                                        "session_id=\(rexSession)"])
    }

    func testRexMapsToRexApp() {
        XCTAssertEqual(TerminalActivator.appleScriptTarget("rex"), "Rex Beta")
    }
}
