import XCTest
@testable import Jattends

final class SessionStatusTests: XCTestCase {
    func testSortOrderPutsAttentionFirst() {
        let sorted = SessionStatus.allCases.sorted()
        XCTAssertEqual(sorted, [.approval, .waiting, .error, .working, .compacting, .idle])
    }

    func testAttentionSet() {
        XCTAssertTrue(SessionStatus.approval.needsAttention)
        XCTAssertTrue(SessionStatus.waiting.needsAttention)
        XCTAssertTrue(SessionStatus.error.needsAttention)
        XCTAssertFalse(SessionStatus.working.needsAttention)
        XCTAssertFalse(SessionStatus.compacting.needsAttention)
        XCTAssertFalse(SessionStatus.idle.needsAttention)
    }

    func testDecodesLegacyActiveAsWorking() throws {
        let status = try JSONDecoder().decode(SessionStatus.self, from: Data("\"active\"".utf8))
        XCTAssertEqual(status, .working)
    }

    func testDecodesUnknownStatusAsIdle() throws {
        let status = try JSONDecoder().decode(SessionStatus.self, from: Data("\"someFutureStatus\"".utf8))
        XCTAssertEqual(status, .idle)
    }
}

final class SessionInfoTests: XCTestCase {
    private func decode(_ json: String) throws -> SessionInfo {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionInfo.self, from: Data(json.utf8))
    }

    func testDecodesLegacyFileWithoutNewFields() throws {
        let session = try decode("""
        {"sessionId":"abc","cwd":"/tmp/proj","status":"waiting",
         "terminalApp":"ghostty","terminalPid":1,"terminalTty":"/dev/ttys001",
         "claudePid":2,"updatedAt":"2026-07-20T10:00:00Z"}
        """)
        XCTAssertEqual(session.status, .waiting)
        XCTAssertNil(session.statusDetail)
        XCTAssertNil(session.lastPrompt)
        XCTAssertEqual(session.projectName, "proj")
    }

    func testDecodesRichFile() throws {
        let session = try decode("""
        {"sessionId":"abc","cwd":"/tmp/proj","status":"approval",
         "statusDetail":"Running: rm -rf build","lastPrompt":"fix the bug",
         "permissionMode":"default","transcriptPath":"/tmp/t.jsonl",
         "updatedAt":"2026-07-20T10:00:00Z"}
        """)
        XCTAssertEqual(session.status, .approval)
        XCTAssertEqual(session.statusDetail, "Running: rm -rf build")
        XCTAssertEqual(session.lastPrompt, "fix the bug")
    }

    func testShortDurationFormatting() {
        let now = Date()
        XCTAssertEqual(SessionInfo.shortDuration(since: now.addingTimeInterval(-42), now: now), "42s")
        XCTAssertEqual(SessionInfo.shortDuration(since: now.addingTimeInterval(-6 * 60), now: now), "6m")
        XCTAssertEqual(SessionInfo.shortDuration(since: now.addingTimeInterval(-(72 * 60)), now: now), "1h 12m")
        XCTAssertEqual(SessionInfo.shortDuration(since: now.addingTimeInterval(60), now: now), "0s")
    }

    func testEffectiveStatusDowngradesStaleWorking() {
        let stale = SessionInfo(
            sessionId: "a", cwd: "/tmp", status: .working,
            updatedAt: Date().addingTimeInterval(-600))
        XCTAssertEqual(stale.effectiveStatus, .idle)

        let fresh = SessionInfo(sessionId: "b", cwd: "/tmp", status: .working)
        XCTAssertEqual(fresh.effectiveStatus, .working)

        // Attention states never expire into idle
        let waiting = SessionInfo(
            sessionId: "c", cwd: "/tmp", status: .waiting,
            updatedAt: Date().addingTimeInterval(-600))
        XCTAssertEqual(waiting.effectiveStatus, .waiting)
    }
}

final class SessionStoreDedupTests: XCTestCase {
    private func session(
        _ id: String, claudePid: Int?, status: SessionStatus, age: TimeInterval = 0
    ) -> (URL, SessionInfo) {
        let info = SessionInfo(
            sessionId: id, cwd: "/tmp/proj", status: status,
            claudePid: claudePid, updatedAt: Date().addingTimeInterval(-age))
        return (URL(fileURLWithPath: "/sessions/\(id).json"), info)
    }

    func testHigherPriorityStatusWinsRegardlessOfAge() {
        let discovered = session("discovered-42", claudePid: 42, status: .idle)
        let real = session("real", claudePid: 42, status: .approval, age: 60)
        let (kept, losers) = SessionStore.dedupeByClaudePid([discovered, real])
        XCTAssertEqual(kept.map(\.sessionId), ["real"])
        XCTAssertEqual(losers, [discovered.0])
    }

    func testMostRecentWinsOnStatusTie() {
        let older = session("older", claudePid: 7, status: .working, age: 120)
        let newer = session("newer", claudePid: 7, status: .working)
        let (kept, losers) = SessionStore.dedupeByClaudePid([older, newer])
        XCTAssertEqual(kept.map(\.sessionId), ["newer"])
        XCTAssertEqual(losers, [older.0])
    }

    func testSessionsWithoutPidAreNeverDeduped() {
        let a = session("a", claudePid: nil, status: .idle)
        let b = session("b", claudePid: nil, status: .idle)
        let (kept, losers) = SessionStore.dedupeByClaudePid([a, b])
        XCTAssertEqual(kept.count, 2)
        XCTAssertTrue(losers.isEmpty)
    }

    func testDistinctPidsAreKept() {
        let a = session("a", claudePid: 1, status: .working)
        let b = session("b", claudePid: 2, status: .working)
        let (kept, losers) = SessionStore.dedupeByClaudePid([a, b])
        XCTAssertEqual(Set(kept.map(\.sessionId)), ["a", "b"])
        XCTAssertTrue(losers.isEmpty)
    }

    func testSortAttentionFirstThenNewest() {
        let idle = SessionInfo(sessionId: "idle", cwd: "/a", status: .idle)
        let approval = SessionInfo(
            sessionId: "approval", cwd: "/b", status: .approval,
            updatedAt: Date().addingTimeInterval(-500))
        let workingOld = SessionInfo(
            sessionId: "workingOld", cwd: "/c", status: .working,
            updatedAt: Date().addingTimeInterval(-100))
        let workingNew = SessionInfo(sessionId: "workingNew", cwd: "/d", status: .working)
        let sorted = SessionStore.sorted([idle, workingOld, approval, workingNew])
        XCTAssertEqual(sorted.map(\.sessionId), ["approval", "workingNew", "workingOld", "idle"])
    }
}
