import Foundation

/// A pending permission request written by the hook while it blocks
/// awaiting the user's decision.
struct ApprovalRequest: Codable, Identifiable {
    let requestId: String
    let sessionId: String
    let cwd: String
    let sessionName: String?
    let toolName: String
    let summary: String
    let createdAt: Date
    /// nil for Claude Code requests (the hook's files don't carry it);
    /// "opencode" for requests answered over opencode's API instead of a
    /// decision file.
    var agent: String? = nil

    var id: String { requestId }

    var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Session name when Claude Code has one, else the project folder name.
    var displayName: String {
        if let sessionName, !sessionName.isEmpty { return sessionName }
        return projectName
    }

    /// Requests older than this are abandoned (the hook gave up waiting).
    var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > 300
    }
}
