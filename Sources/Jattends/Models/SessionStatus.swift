import Foundation

enum SessionStatus: String, Codable, Comparable, CaseIterable {
    case approval    // Blocked on a permission decision
    case waiting     // Waiting for user input or an answer
    case error       // Turn failed (rate limit, API error, ...)
    case working     // Claude is processing
    case compacting  // Context compaction in progress
    case idle        // Session exists but nothing happening

    /// Whether this status needs the user's attention (badge + notification).
    var needsAttention: Bool {
        switch self {
        case .approval, .waiting, .error: return true
        case .working, .compacting, .idle: return false
        }
    }

    /// Sort order: attention states first, then activity, then idle.
    private var sortOrder: Int {
        switch self {
        case .approval: return 0
        case .waiting: return 1
        case .error: return 2
        case .working: return 3
        case .compacting: return 4
        case .idle: return 5
        }
    }

    static func < (lhs: SessionStatus, rhs: SessionStatus) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    var label: String {
        switch self {
        case .approval: return "Needs approval"
        case .waiting: return "Waiting"
        case .error: return "Error"
        case .working: return "Working"
        case .compacting: return "Compacting"
        case .idle: return "Ready"
        }
    }

    var iconColor: String {
        switch self {
        case .approval, .waiting, .error: return "orange"
        case .working: return "green"
        case .compacting: return "blue"
        case .idle: return "gray"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "active": self = .working // legacy hook value
        default: self = SessionStatus(rawValue: raw) ?? .idle
        }
    }
}
