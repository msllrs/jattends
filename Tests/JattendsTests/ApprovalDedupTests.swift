import XCTest
@testable import Jattends

final class ApprovalDedupTests: XCTestCase {
    // Regression: a PermissionRequest both creates an approval request and
    // sets the session's status to approval, so the same session showed up
    // twice — under "Pending approvals" and again in the attention group.
    func testSessionsWithPendingApprovalsAreHidden() {
        let approving = SessionInfo(sessionId: "a", cwd: "/p/one", status: .approval)
        let waiting = SessionInfo(sessionId: "b", cwd: "/p/two", status: .waiting)
        let working = SessionInfo(sessionId: "c", cwd: "/p/three", status: .working)

        let visible = SessionStore.hidingPendingApprovals(
            [approving, waiting, working], approvalSessionIds: ["a"])

        XCTAssertEqual(visible.map(\.sessionId), ["b", "c"])
    }

    func testNoApprovalsIsPassthrough() {
        let sessions = [
            SessionInfo(sessionId: "a", cwd: "/p/one", status: .waiting),
            SessionInfo(sessionId: "b", cwd: "/p/two", status: .idle),
        ]
        let visible = SessionStore.hidingPendingApprovals(sessions, approvalSessionIds: [])
        XCTAssertEqual(visible.map(\.sessionId), ["a", "b"])
    }
}
