import XCTest
@testable import Jattends

/// opencode runs every session inside one background service; Jattends
/// follows its authenticated SSE stream (/api/event) instead of hooks.
/// Payloads below were captured from opencode 2.0.25.
final class OpencodeTests: XCTestCase {
    private let sid = "ses_e7e05a30fffecZwLVB1LqpSbDA"
    private let dir = "/Users/me/git/proj"

    private func line(_ type: String, _ data: String, location: Bool = true) -> String {
        let loc = location ? #","location":{"directory":"\#(dir)"}"# : ""
        return #"data: {"id":"evt_1","created":1793182031089,"type":"\#(type)"\#(loc),"data":\#(data)}"#
    }

    // MARK: - SSE parsing

    func testParsesSessionCreated() {
        let l = line("session.created", #"{"sessionID":"\#(sid)","slug":"happy-planet","version":"2.0.25","location":{"directory":"\#(dir)"}}"#)
        XCTAssertEqual(OpencodeEvent.parse(sseLine: l), .sessionCreated(sessionID: sid, directory: dir))
    }

    func testParsesExecutionLifecycle() {
        XCTAssertEqual(OpencodeEvent.parse(sseLine: line("session.execution.started", #"{"sessionID":"\#(sid)"}"#, location: false)),
                       .executionStarted(sessionID: sid))
        XCTAssertEqual(OpencodeEvent.parse(sseLine: line("session.execution.succeeded", #"{"sessionID":"\#(sid)"}"#, location: false)),
                       .executionEnded(sessionID: sid, outcome: .succeeded))
        XCTAssertEqual(OpencodeEvent.parse(sseLine: line("session.execution.interrupted", #"{"sessionID":"\#(sid)"}"#, location: false)),
                       .executionEnded(sessionID: sid, outcome: .interrupted))
        XCTAssertEqual(OpencodeEvent.parse(sseLine: line("session.execution.failed", #"{"sessionID":"\#(sid)","error":{"message":"rate limited"}}"#, location: false)),
                       .executionEnded(sessionID: sid, outcome: .failed(message: "rate limited")))
        XCTAssertEqual(OpencodeEvent.parse(sseLine: line("session.error", #"{"sessionID":"\#(sid)","message":"boom"}"#)),
                       .executionEnded(sessionID: sid, outcome: .failed(message: "boom")))
        XCTAssertEqual(OpencodeEvent.parse(sseLine: line("session.idle", #"{"sessionID":"\#(sid)"}"#)),
                       .executionEnded(sessionID: sid, outcome: .succeeded))
    }

    func testParsesToolCalledIntoDetail() {
        let l = line("session.tool.called", #"{"sessionID":"\#(sid)","assistantMessageID":"msg_1","id":"call_1","input":{"command":"npm test"},"executed":false}"#)
        XCTAssertEqual(OpencodeEvent.parse(sseLine: l), .toolCalled(sessionID: sid, detail: "Running: npm test"))
        let edit = line("session.tool.called", #"{"sessionID":"\#(sid)","id":"call_2","input":{"filePath":"/a/b/Store.swift"}}"#)
        XCTAssertEqual(OpencodeEvent.parse(sseLine: edit), .toolCalled(sessionID: sid, detail: "Editing: Store.swift"))
        let other = line("session.tool.called", #"{"sessionID":"\#(sid)","id":"call_3","input":{}}"#)
        XCTAssertEqual(OpencodeEvent.parse(sseLine: other), .toolCalled(sessionID: sid, detail: nil))
    }

    func testParsesPermissionAskedAndReplied() {
        let asked = line("permission.asked", #"{"id":"per_1","sessionID":"\#(sid)","action":"shell","resources":["echo jattends-perm"],"save":["echo *"],"source":{"type":"tool","messageID":"msg_1","id":"call_1"}}"#)
        XCTAssertEqual(OpencodeEvent.parse(sseLine: asked),
                       .permissionAsked(OpencodePermission(id: "per_1", sessionID: sid, action: "shell",
                                                           resources: ["echo jattends-perm"], directory: dir)))
        let replied = line("permission.replied", #"{"sessionID":"\#(sid)","requestID":"per_1","reply":"reject"}"#)
        XCTAssertEqual(OpencodeEvent.parse(sseLine: replied), .permissionResolved(sessionID: sid, requestID: "per_1"))
        let rejected = line("permission.rejected", #"{"sessionID":"\#(sid)","requestID":"per_1"}"#)
        XCTAssertEqual(OpencodeEvent.parse(sseLine: rejected), .permissionResolved(sessionID: sid, requestID: "per_1"))
    }

    func testParsesForms() {
        XCTAssertEqual(OpencodeEvent.parse(sseLine: line("form.created", #"{"id":"frm_1","sessionID":"\#(sid)","title":"Which DB?","fields":{}}"#)),
                       .formOpened(sessionID: sid, formID: "frm_1", title: "Which DB?"))
        XCTAssertEqual(OpencodeEvent.parse(sseLine: line("form.replied", #"{"id":"frm_1","sessionID":"\#(sid)"}"#)),
                       .formClosed(sessionID: sid, formID: "frm_1"))
        XCTAssertEqual(OpencodeEvent.parse(sseLine: line("form.cancelled", #"{"formID":"frm_1","sessionID":"\#(sid)"}"#)),
                       .formClosed(sessionID: sid, formID: "frm_1"))
    }

    func testParsesSessionUpdatedTitleAndDeleted() {
        XCTAssertEqual(OpencodeEvent.parse(sseLine: line("session.updated", #"{"sessionID":"\#(sid)","title":"Fix scroll overlay"}"#)),
                       .titleChanged(sessionID: sid, title: "Fix scroll overlay"))
        XCTAssertEqual(OpencodeEvent.parse(sseLine: line("session.deleted", #"{"sessionID":"\#(sid)"}"#)),
                       .sessionDeleted(sessionID: sid))
    }

    func testIgnoresNoise() {
        XCTAssertNil(OpencodeEvent.parse(sseLine: ": heartbeat"))
        XCTAssertNil(OpencodeEvent.parse(sseLine: ""))
        XCTAssertNil(OpencodeEvent.parse(sseLine: #"data: {"id":"evt_x","type":"server.connected","data":{}}"#))
        XCTAssertNil(OpencodeEvent.parse(sseLine: line("session.reasoning.delta", #"{"sessionID":"\#(sid)","delta":"hm"}"#)))
        XCTAssertNil(OpencodeEvent.parse(sseLine: "data: {not json"))
    }

    // MARK: - State

    private func reduce(_ events: [OpencodeEvent]) -> OpencodeSessionState? {
        var all: [String: OpencodeSessionState] = [:]
        let t0 = Date(timeIntervalSince1970: 1_793_182_031)
        for (i, e) in events.enumerated() {
            OpencodeSessionState.apply(e, to: &all, at: t0.addingTimeInterval(Double(i)))
        }
        return all[sid]
    }

    func testStatusFollowsExecution() {
        XCTAssertEqual(reduce([.sessionCreated(sessionID: sid, directory: dir)])?.status, .idle)
        XCTAssertEqual(reduce([.sessionCreated(sessionID: sid, directory: dir),
                               .executionStarted(sessionID: sid)])?.status, .working)
        let done = reduce([.sessionCreated(sessionID: sid, directory: dir),
                           .executionStarted(sessionID: sid),
                           .toolCalled(sessionID: sid, detail: "Running: ls"),
                           .executionEnded(sessionID: sid, outcome: .succeeded)])
        XCTAssertEqual(done?.status, .idle)
        XCTAssertNil(done?.detail)
        let failed = reduce([.sessionCreated(sessionID: sid, directory: dir),
                             .executionEnded(sessionID: sid, outcome: .failed(message: "rate limited"))])
        XCTAssertEqual(failed?.status, .error)
        XCTAssertEqual(failed?.detail, "rate limited")
    }

    func testToolCallSetsWorkingDetail() {
        let s = reduce([.sessionCreated(sessionID: sid, directory: dir),
                        .executionStarted(sessionID: sid),
                        .toolCalled(sessionID: sid, detail: "Running: ls")])
        XCTAssertEqual(s?.status, .working)
        XCTAssertEqual(s?.detail, "Running: ls")
    }

    /// Pending permission outranks everything until it's resolved; a
    /// pending question (form) shows as waiting.
    func testPermissionAndFormOverlayStatus() {
        let perm = OpencodePermission(id: "per_1", sessionID: sid, action: "shell", resources: ["rm -rf build"], directory: dir)
        var events: [OpencodeEvent] = [.sessionCreated(sessionID: sid, directory: dir),
                                       .executionStarted(sessionID: sid),
                                       .permissionAsked(perm)]
        XCTAssertEqual(reduce(events)?.status, .approval)
        events.append(.permissionResolved(sessionID: sid, requestID: "per_1"))
        XCTAssertEqual(reduce(events)?.status, .working)
        events.append(.formOpened(sessionID: sid, formID: "frm_1", title: "Which DB?"))
        XCTAssertEqual(reduce(events)?.status, .waiting)
        XCTAssertEqual(reduce(events)?.detail, "Which DB?")
        events.append(.formClosed(sessionID: sid, formID: "frm_1"))
        XCTAssertEqual(reduce(events)?.status, .working)
    }

    /// Events can arrive for a session Jattends never saw created (it
    /// started before the app): the session is created on first sight,
    /// with the directory filled in when an event carries one.
    func testUnknownSessionIsCreatedOnFirstEvent() {
        let perm = OpencodePermission(id: "per_1", sessionID: sid, action: "edit", resources: ["a.swift"], directory: dir)
        let s = reduce([.executionStarted(sessionID: sid), .permissionAsked(perm)])
        XCTAssertEqual(s?.status, .approval)
        XCTAssertEqual(s?.directory, dir)
    }

    func testDeletedSessionDisappears() {
        XCTAssertNil(reduce([.sessionCreated(sessionID: sid, directory: dir), .sessionDeleted(sessionID: sid)]))
    }

    func testTitleBecomesSessionName() {
        let s = reduce([.sessionCreated(sessionID: sid, directory: dir),
                        .titleChanged(sessionID: sid, title: "Fix scroll overlay")])
        XCTAssertEqual(s?.title, "Fix scroll overlay")
    }

    // MARK: - Bridging into Jattends models

    func testSessionInfoBridge() {
        var state = OpencodeSessionState(sessionID: sid, directory: dir, updatedAt: Date())
        state.status = .working
        state.detail = "Running: ls"
        state.title = "Fix scroll"
        let info = state.sessionInfo(terminal: OpencodeTerminal(pid: 46063, tty: "/dev/ttys011", app: "ghostty", appPid: 45900))
        XCTAssertEqual(info.sessionId, sid)
        XCTAssertEqual(info.agent, "opencode")
        XCTAssertEqual(info.cwd, dir)
        XCTAssertEqual(info.status, .working)
        XCTAssertEqual(info.statusDetail, "Running: ls")
        XCTAssertEqual(info.sessionName, "Fix scroll")
        XCTAssertEqual(info.terminalTty, "/dev/ttys011")
        XCTAssertEqual(info.terminalApp, "ghostty")
        XCTAssertEqual(info.terminalPid, 45900)
        // The opencode TUI isn't a claude process: liveness is tracked by
        // the monitor, so the store's claudePid checks must not apply.
        XCTAssertNil(info.claudePid)
    }

    func testApprovalBridge() {
        let perm = OpencodePermission(id: "per_1", sessionID: sid, action: "shell",
                                      resources: ["echo a", "echo b"], directory: dir)
        let req = perm.approvalRequest(sessionName: "Fix scroll", createdAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(req.requestId, "per_1")
        XCTAssertEqual(req.sessionId, sid)
        XCTAssertEqual(req.toolName, "shell")
        XCTAssertEqual(req.summary, "echo a, echo b")
        XCTAssertEqual(req.agent, "opencode")
        XCTAssertEqual(req.displayName, "Fix scroll")
    }

    func testReplyBody() {
        XCTAssertEqual(OpencodeClient.replyBody(allow: true), ["decision": "once"])
        XCTAssertEqual(OpencodeClient.replyBody(allow: false)["decision"], "reject")
    }

    // MARK: - Service discovery & auth

    func testParsesServiceStatusURL() {
        XCTAssertEqual(OpencodeClient.serverURL(fromStatus: "http://127.0.0.1:49374\n"),
                       URL(string: "http://127.0.0.1:49374"))
        XCTAssertNil(OpencodeClient.serverURL(fromStatus: "not running\n"))
    }

    func testBasicAuthHeader() {
        // user "opencode", password from ~/.config/opencode/service.json
        XCTAssertEqual(OpencodeClient.authorizationHeader(password: "pw"),
                       "Basic " + Data("opencode:pw".utf8).base64EncodedString())
        XCTAssertEqual(OpencodeClient.password(fromServiceJSON: Data(#"{"password":"abc"}"#.utf8)), "abc")
        XCTAssertNil(OpencodeClient.password(fromServiceJSON: Data("{}".utf8)))
    }

    // MARK: - Terminal matching

    /// The TUI runs as `opencode` with a tty; the service (`opencode serve`)
    /// and stray daemons have none. Match by cwd, then walk up to the
    /// terminal app for focus.
    func testMatchesTUIByDirectory() {
        let procs: [Int: OpencodeProc] = [
            45900: .init(ppid: 1, tty: nil, comm: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
            45923: .init(ppid: 45900, tty: "ttys011", comm: "-zsh"),
            46063: .init(ppid: 45923, tty: "ttys011", comm: "opencode"),
            46065: .init(ppid: 46063, tty: nil, comm: "/opt/homebrew/Cellar/opencode/2.0.25/bin/opencode"),
            51045: .init(ppid: 1, tty: nil, comm: "opencode"),
            60000: .init(ppid: 45923, tty: "ttys012", comm: "opencode"),
        ]
        let cwds = [46063: dir, 60000: "/Users/me/other", 51045: dir]
        let t = OpencodeTerminal.match(directory: dir, procs: procs, cwds: cwds)
        XCTAssertEqual(t, OpencodeTerminal(pid: 46063, tty: "/dev/ttys011", app: "ghostty", appPid: 45900))
        XCTAssertNil(OpencodeTerminal.match(directory: "/nowhere", procs: procs, cwds: cwds))
    }

    func testSettingDefaultsOn() {
        let d = UserDefaults(suiteName: "jattends-test-\(UUID().uuidString)")!
        XCTAssertTrue(OpencodeClient.isEnabled(d))
        d.set(false, forKey: OpencodeClient.enabledKey)
        XCTAssertFalse(OpencodeClient.isEnabled(d))
    }
}
