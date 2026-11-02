import XCTest
@testable import Jattends

/// Rex receives each pane's state straight from Claude Code via OSC 7501
/// (program status). For Rex sessions that is the default status source;
/// hooks remain the fallback and can be chosen in Settings.
final class RexProgramStatusTests: XCTestCase {
    private let block = "block:01a17930-e285-72f1-af70-533882e2596c"

    private func record(_ state: String, kind: String? = nil, app: String? = nil,
                        msg: String? = nil, owner: String = "claude",
                        at: String = "2026-10-26T22:00:06Z") -> RexStatusRecord {
        let f = ISO8601DateFormatter()
        return RexStatusRecord(id: "", state: state, kind: kind, app: app, effectiveApp: app,
                               msg: msg, updatedAt: f.date(from: at)!,
                               owner: .init(pid: 42, name: owner))
    }

    private func rexSession(_ status: SessionStatus = .idle, detail: String? = nil) -> SessionInfo {
        SessionInfo(sessionId: "s1", cwd: "/tmp/p", status: status, terminalApp: "rex",
                    rexBlock: block, statusDetail: detail)
    }

    // MARK: - Watcher output (one JSON line per event)

    /// Captured from a live `rex do -e <watcherScript> --all`.
    func testParsesChangedEventLine() {
        let line = #"{"type":"changed","block":"block:01a17a3a","record":{"state":"blocked","kind":"permission","app":"claude-code","effective_app":"claude-code","msg":"Allow \"Bash\": ls","updated_at":"2026-10-26T22:00:06.80162Z","owner":{"pid":60182,"name":"bash"}}}"#
        guard case .changed(let b, let r)? = RexProgramStatus.parseEventLine(line) else {
            return XCTFail("not parsed")
        }
        XCTAssertEqual(b, "block:01a17a3a")
        XCTAssertEqual(r.state, "blocked")
        XCTAssertEqual(r.kind, "permission")
        XCTAssertEqual(r.msg, #"Allow "Bash": ls"#)
        XCTAssertEqual(r.owner?.name, "bash")
    }

    func testParsesRemovedEventLine() {
        let line = #"{"type":"removed","block":"block:01a17a3a","ids":[""]}"#
        XCTAssertEqual(RexProgramStatus.parseEventLine(line), .removed(block: "block:01a17a3a", ids: [""]))
    }

    func testIgnoresGarbageLines() {
        XCTAssertNil(RexProgramStatus.parseEventLine("listening: 2 handlers, every session"))
        XCTAssertNil(RexProgramStatus.parseEventLine(#"{"type":"other"}"#))
        XCTAssertNil(RexProgramStatus.parseEventLine(""))
    }

    /// `rex block call -s S -b B program_status` output, for the initial snapshot.
    func testParsesSnapshot() {
        let json = #"{"records":[{"state":"working","updated_at":"2026-10-26T21:51:02.31687Z","owner":{"pid":16137,"name":"claude"}}]}"#
        let records = RexProgramStatus.parseSnapshot(json)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.state, "working")
        XCTAssertEqual(RexProgramStatus.parseSnapshot("Error: block not found"), [])
    }

    // MARK: - Mapping

    func testStateMapping() {
        XCTAssertEqual(RexProgramStatus.sessionStatus(for: record("working")), .working)
        XCTAssertEqual(RexProgramStatus.sessionStatus(for: record("blocked", kind: "permission")), .approval)
        XCTAssertEqual(RexProgramStatus.sessionStatus(for: record("blocked", kind: "question")), .waiting)
        XCTAssertEqual(RexProgramStatus.sessionStatus(for: record("blocked", kind: "auth")), .waiting)
        XCTAssertEqual(RexProgramStatus.sessionStatus(for: record("blocked")), .waiting)
        XCTAssertEqual(RexProgramStatus.sessionStatus(for: record("error")), .error)
        XCTAssertEqual(RexProgramStatus.sessionStatus(for: record("idle")), .idle)
        XCTAssertEqual(RexProgramStatus.sessionStatus(for: record("done")), .idle)
        // Unknown future states don't override the hook's status
        XCTAssertNil(RexProgramStatus.sessionStatus(for: record("hibernating")))
    }

    /// A pane can hold records from several programs (a build under Claude's
    /// Bash tool, say). Claude's own record wins; otherwise the newest.
    func testPrefersClaudeRecord() {
        let build = record("working", app: "cargo", owner: "cargo", at: "2026-10-26T22:00:09Z")
        let claudeByOwner = record("blocked", kind: "permission", owner: "claude", at: "2026-10-26T22:00:01Z")
        XCTAssertEqual(RexProgramStatus.preferredRecord([build, claudeByOwner]), claudeByOwner)

        let claudeByApp = record("idle", app: "claude-code", owner: "node", at: "2026-10-26T22:00:01Z")
        XCTAssertEqual(RexProgramStatus.preferredRecord([build, claudeByApp]), claudeByApp)

        let older = record("idle", app: "make", owner: "make", at: "2026-10-26T21:00:00Z")
        XCTAssertEqual(RexProgramStatus.preferredRecord([older, build]), build)
        XCTAssertNil(RexProgramStatus.preferredRecord([]))
    }

    // MARK: - Applying to sessions

    func testProgramStatusOverridesHookStatusForRexSessions() {
        let records = [block: [record("blocked", kind: "permission", msg: "Allow Bash: ls")]]
        let out = RexProgramStatus.applying(records, to: [rexSession(.working)], source: .programStatus)
        XCTAssertEqual(out.first?.status, .approval)
        XCTAssertEqual(out.first?.statusDetail, "Allow Bash: ls")
    }

    func testHooksSourceLeavesSessionsAlone() {
        let records = [block: [record("blocked", kind: "permission")]]
        let out = RexProgramStatus.applying(records, to: [rexSession(.working, detail: "Running: ls")], source: .hooks)
        XCTAssertEqual(out.first?.status, .working)
        XCTAssertEqual(out.first?.statusDetail, "Running: ls")
    }

    /// No record yet (older Claude Code, or the snapshot hasn't landed):
    /// fall back to whatever the hooks said.
    func testFallsBackToHooksWithoutRecord() {
        let out = RexProgramStatus.applying([:], to: [rexSession(.waiting, detail: "q?")], source: .programStatus)
        XCTAssertEqual(out.first?.status, .waiting)
        XCTAssertEqual(out.first?.statusDetail, "q?")
    }

    func testNonRexSessionsUntouched() {
        let ghostty = SessionInfo(sessionId: "g", cwd: "/tmp/g", status: .working, terminalApp: "ghostty")
        let records = [block: [record("error")]]
        XCTAssertEqual(RexProgramStatus.applying(records, to: [ghostty], source: .programStatus).first?.status, .working)
    }

    /// A record without a message keeps no stale hook detail around.
    func testRecordWithoutMessageClearsDetail() {
        let out = RexProgramStatus.applying([block: [record("idle")]],
                                            to: [rexSession(.working, detail: "Running: ls")], source: .programStatus)
        XCTAssertEqual(out.first?.status, .idle)
        XCTAssertNil(out.first?.statusDetail)
    }

    // MARK: - Setting

    func testSourceDefaultsToProgramStatus() {
        let defaults = UserDefaults(suiteName: "jattends-test-\(UUID().uuidString)")!
        XCTAssertEqual(RexStatusSource.current(defaults), .programStatus)
        defaults.set("hooks", forKey: RexStatusSource.defaultsKey)
        XCTAssertEqual(RexStatusSource.current(defaults), .hooks)
        defaults.set("nonsense", forKey: RexStatusSource.defaultsKey)
        XCTAssertEqual(RexStatusSource.current(defaults), .programStatus)
    }

    /// The watcher script subscribes to both namespaced block events.
    func testWatcherScriptSubscribesToStatusEvents() {
        let s = RexProgramStatus.watcherScript
        XCTAssertTrue(s.contains(#"rex.on("com.superlogical.terminal.program_status_changed""#))
        XCTAssertTrue(s.contains(#"rex.on("com.superlogical.terminal.program_status_removed""#))
    }
}
