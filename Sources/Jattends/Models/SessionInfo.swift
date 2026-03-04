import Foundation

struct SessionInfo: Codable, Identifiable {
    let sessionId: String
    let cwd: String
    let status: SessionStatus
    let terminalApp: String?
    let terminalPid: Int?
    let terminalTty: String?
    let claudePid: Int?
    let updatedAt: Date

    var id: String { sessionId }

    /// Derive a short project name from the working directory.
    var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Whether this session is stale (older than 24 hours).
    var isStale: Bool {
        Date().timeIntervalSince(updatedAt) > 86400
    }
}
