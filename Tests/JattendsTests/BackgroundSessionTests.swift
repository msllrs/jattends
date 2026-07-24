import XCTest
@testable import Jattends

final class BackgroundSessionTests: XCTestCase {
    private func session(
        _ id: String, status: SessionStatus = .idle, kind: String? = nil,
        name: String? = nil
    ) -> SessionInfo {
        SessionInfo(sessionId: id, cwd: "/tmp/proj", status: status,
                    sessionName: name, kind: kind)
    }

    private func decode(_ json: String) throws -> SessionInfo {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionInfo.self, from: Data(json.utf8))
    }

    // MARK: - Model

    func testKindDecodesAndFlagsBackground() throws {
        let bg = try decode("""
        {"sessionId":"abc","cwd":"/tmp/proj","status":"idle","kind":"bg",
         "updatedAt":"2026-07-24T10:00:00Z"}
        """)
        XCTAssertEqual(bg.kind, "bg")
        XCTAssertTrue(bg.isBackground)
    }

    func testMissingKindIsNotBackground() throws {
        let fg = try decode("""
        {"sessionId":"abc","cwd":"/tmp/proj","status":"idle",
         "updatedAt":"2026-07-24T10:00:00Z"}
        """)
        XCTAssertNil(fg.kind)
        XCTAssertFalse(fg.isBackground)
    }

    func testInteractiveKindIsNotBackground() {
        XCTAssertFalse(session("a", kind: "interactive").isBackground)
    }

    // MARK: - Background group visibility (Settings → Application)

    func testShowAllIncludesEveryBackgroundSession() {
        let sessions = [
            session("bg-idle", status: .idle, kind: "bg"),
            session("bg-work", status: .working, kind: "bg"),
            session("fg-idle", status: .idle),
        ]
        let visible = SessionStore.visibleBackground(sessions, mode: "all")
        XCTAssertEqual(visible.map(\.sessionId), ["bg-idle", "bg-work"])
    }

    func testOnlyActiveShowsWorkingAndCompacting() {
        let sessions = [
            session("bg-idle", status: .idle, kind: "bg"),
            session("bg-work", status: .working, kind: "bg"),
            session("bg-compact", status: .compacting, kind: "bg"),
        ]
        let visible = SessionStore.visibleBackground(sessions, mode: "active")
        XCTAssertEqual(visible.map(\.sessionId), ["bg-work", "bg-compact"])
    }

    func testHiddenShowsNone() {
        let sessions = [
            session("bg-work", status: .working, kind: "bg"),
            session("bg-idle", status: .idle, kind: "bg"),
        ]
        XCTAssertTrue(SessionStore.visibleBackground(sessions, mode: "hidden").isEmpty)
    }

    func testUnknownModeBehavesLikeShowAll() {
        let sessions = [session("bg-idle", status: .idle, kind: "bg")]
        XCTAssertEqual(
            SessionStore.visibleBackground(sessions, mode: "someFutureMode").count, 1)
    }

    func testAttentionBackgroundStaysOutOfBackgroundGroup() {
        // Attention rows always surface in the waiting group instead,
        // regardless of the visibility mode.
        let sessions = [
            session("bg-approval", status: .approval, kind: "bg"),
            session("bg-waiting", status: .waiting, kind: "bg"),
            session("bg-error", status: .error, kind: "bg"),
        ]
        for mode in ["all", "active", "hidden"] {
            XCTAssertTrue(
                SessionStore.visibleBackground(sessions, mode: mode).isEmpty,
                "mode \(mode) leaked attention sessions into the background group")
        }
    }

    // MARK: - Named tasks are first-class sessions

    // "Background" for display purposes means an ANONYMOUS daemon session.
    // A named task is real work the user engaged with (typed an intent or
    // opened it in a window — attachment itself isn't observable), so it
    // lives in the normal groups and ignores the visibility setting.

    func testNamedBackgroundTaskJoinsIdleGroup() {
        let sessions = [
            session("named", status: .idle, kind: "bg", name: "pr review #46498"),
            session("anon", status: .idle, kind: "bg"),
        ]
        XCTAssertEqual(SessionStore.idleGroup(sessions).map(\.sessionId), ["named"])
        XCTAssertEqual(
            SessionStore.visibleBackground(sessions, mode: "all").map(\.sessionId),
            ["anon"])
    }

    func testNamedBackgroundTaskJoinsWorkingGroup() {
        let sessions = [
            session("named", status: .working, kind: "bg", name: "show more/less"),
        ]
        XCTAssertEqual(SessionStore.workingGroup(sessions).map(\.sessionId), ["named"])
        XCTAssertTrue(SessionStore.visibleBackground(sessions, mode: "all").isEmpty)
    }

    func testNamedTaskIgnoresHiddenMode() {
        let sessions = [
            session("named", status: .idle, kind: "bg", name: "open explore"),
            session("anon", status: .idle, kind: "bg"),
        ]
        XCTAssertTrue(SessionStore.visibleBackground(sessions, mode: "hidden").isEmpty)
        XCTAssertEqual(SessionStore.idleGroup(sessions).map(\.sessionId), ["named"])
    }

    // MARK: - Foreground groups exclude background sessions

    func testWorkingGroupExcludesBackground() {
        let sessions = [
            session("fg", status: .working),
            session("bg", status: .working, kind: "bg"),
        ]
        XCTAssertEqual(SessionStore.workingGroup(sessions).map(\.sessionId), ["fg"])
    }

    func testIdleGroupExcludesBackground() {
        let sessions = [
            session("fg", status: .idle),
            session("bg", status: .idle, kind: "bg"),
        ]
        XCTAssertEqual(SessionStore.idleGroup(sessions).map(\.sessionId), ["fg"])
    }

    func testWaitingGroupKeepsBackgroundSessions() {
        // A background session that needs attention must never be filtered out.
        let sessions = [
            session("fg", status: .waiting),
            session("bg", status: .approval, kind: "bg"),
        ]
        XCTAssertEqual(
            SessionStore.waitingGroup(sessions).map(\.sessionId), ["fg", "bg"])
    }
}

final class ViewerSessionTests: XCTestCase {
    // A `viewer` session is a terminal displaying the background-task UI —
    // its window is already represented by the named task rows, so a bare
    // one (idle, never prompted, unnamed) hides from the Ready group.

    private func viewer(
        _ id: String, status: SessionStatus = .idle,
        lastPrompt: String? = nil, sessionName: String? = nil
    ) -> SessionInfo {
        SessionInfo(sessionId: id, cwd: "/tmp/proj", status: status,
                    sessionName: sessionName, viewer: true,
                    lastPrompt: lastPrompt)
    }

    func testViewerDecodesAndDefaultsNil() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionInfo.self, from: Data("""
        {"sessionId":"abc","cwd":"/tmp/proj","status":"idle","viewer":true,
         "updatedAt":"2026-07-24T10:00:00Z"}
        """.utf8))
        XCTAssertEqual(decoded.viewer, true)

        let legacy = try decoder.decode(SessionInfo.self, from: Data("""
        {"sessionId":"abc","cwd":"/tmp/proj","status":"idle",
         "updatedAt":"2026-07-24T10:00:00Z"}
        """.utf8))
        XCTAssertNil(legacy.viewer)
    }

    func testIdleGroupHidesBareViewerTerminals() {
        let sessions = [
            SessionInfo(sessionId: "plain", cwd: "/tmp/proj", status: .idle),
            viewer("bare"),
        ]
        XCTAssertEqual(SessionStore.idleGroup(sessions).map(\.sessionId), ["plain"])
    }

    func testViewerWithHistoryStaysVisible() {
        // Once the terminal has been used as a real session, never hide it.
        let sessions = [
            viewer("prompted", lastPrompt: "fix the bug"),
            viewer("named", sessionName: "topic title"),
        ]
        XCTAssertEqual(
            SessionStore.idleGroup(sessions).map(\.sessionId), ["prompted", "named"])
    }

    func testActiveViewerStaysInWorkingGroup() {
        let sessions = [viewer("busy", status: .working)]
        XCTAssertEqual(SessionStore.workingGroup(sessions).map(\.sessionId), ["busy"])
    }
}
