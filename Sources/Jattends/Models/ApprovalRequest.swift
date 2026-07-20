import Foundation

/// A pending permission request written by the hook while it blocks
/// awaiting the user's decision.
struct ApprovalRequest: Codable, Identifiable {
    let requestId: String
    let sessionId: String
    let cwd: String
    let toolName: String
    let summary: String
    let createdAt: Date

    var id: String { requestId }

    var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Requests older than this are abandoned (the hook gave up waiting).
    var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > 300
    }
}
