import Foundation

enum SessionStatus: String, Codable, Comparable {
    case waiting   // Needs user attention (idle prompt, tool approval, etc.)
    case active    // Claude is working
    case idle      // Session exists but nothing happening

    /// Sort order: waiting first, then active, then idle.
    private var sortOrder: Int {
        switch self {
        case .waiting: return 0
        case .active: return 1
        case .idle: return 2
        }
    }

    static func < (lhs: SessionStatus, rhs: SessionStatus) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    var label: String {
        switch self {
        case .waiting: return "Waiting"
        case .active: return "Working"
        case .idle: return "Ready"
        }
    }

    var iconColor: String {
        switch self {
        case .waiting: return "orange"
        case .active: return "green"
        case .idle: return "gray"
        }
    }
}
