import Foundation

struct SessionInfo: Codable, Identifiable {
    let sessionId: String
    let cwd: String
    var status: SessionStatus
    let terminalApp: String?
    let terminalPid: Int?
    let terminalTty: String?
    let claudePid: Int?
    let updatedAt: Date
    let statusDetail: String?
    let lastPrompt: String?
    let permissionMode: String?
    let transcriptPath: String?
    let subagentCount: Int?
    let turnStartedAt: Date?

    init(
        sessionId: String,
        cwd: String,
        status: SessionStatus,
        terminalApp: String? = nil,
        terminalPid: Int? = nil,
        terminalTty: String? = nil,
        claudePid: Int? = nil,
        updatedAt: Date = Date(),
        statusDetail: String? = nil,
        lastPrompt: String? = nil,
        permissionMode: String? = nil,
        transcriptPath: String? = nil,
        subagentCount: Int? = nil,
        turnStartedAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.status = status
        self.terminalApp = terminalApp
        self.terminalPid = terminalPid
        self.terminalTty = terminalTty
        self.claudePid = claudePid
        self.updatedAt = updatedAt
        self.statusDetail = statusDetail
        self.lastPrompt = lastPrompt
        self.permissionMode = permissionMode
        self.transcriptPath = transcriptPath
        self.subagentCount = subagentCount
        self.turnStartedAt = turnStartedAt
    }

    /// Compact elapsed-time label: "42s", "6m", "1h 12m".
    static func shortDuration(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    var id: String { sessionId }

    /// Derive a short project name from the working directory.
    var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Whether this session is stale (older than 24 hours).
    var isStale: Bool {
        Date().timeIntervalSince(updatedAt) > 86400
    }

    /// A working session that hasn't updated in this long is shown as idle —
    /// PostToolUse events flow constantly while Claude is actually working.
    static let workingTimeout: TimeInterval = 300

    /// Status adjusted for staleness: stale "working"/"compacting" become idle.
    var effectiveStatus: SessionStatus {
        if (status == .working || status == .compacting),
           Date().timeIntervalSince(updatedAt) > Self.workingTimeout {
            return .idle
        }
        return status
    }
}
