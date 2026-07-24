import Foundation

struct SessionInfo: Codable, Identifiable {
    let sessionId: String
    let cwd: String
    var status: SessionStatus
    /// Claude Code's session display name (auto topic title or /rename name),
    /// injected by SessionStore from the labels/ sidecar — not part of the
    /// session JSON itself.
    var sessionName: String?
    /// "bg" for daemon-run background task sessions, "interactive" for
    /// terminal ones; absent in legacy files, treated as interactive.
    let kind: String?
    /// True for a terminal claude connected to the background-task daemon
    /// (task list or attached task); absent in legacy files.
    let viewer: Bool?
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
        sessionName: String? = nil,
        kind: String? = nil,
        viewer: Bool? = nil,
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
        self.sessionName = sessionName
        self.kind = kind
        self.viewer = viewer
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

    /// Whether this session runs under the background-task daemon.
    var isBackground: Bool { kind == "bg" }

    /// A daemon session the user hasn't engaged with — no name means no
    /// typed intent and no task title. Named tasks are first-class sessions
    /// for display (window attachment itself isn't observable). Relies on
    /// sessionName being injected from the labels sidecar before grouping.
    var isAnonymousBackground: Bool { isBackground && sessionName == nil }

    /// A viewer terminal that was never used as a real session (no prompt
    /// history, no name) — its window is already represented by the named
    /// Background task rows. Status is the group filter's concern, not ours.
    var isBareViewer: Bool { viewer == true && lastPrompt == nil && sessionName == nil }

    /// Derive a short project name from the working directory.
    var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Session name when Claude Code has one, else the project folder name.
    /// Distinguishes parallel sessions that share a working directory.
    var displayName: String {
        if let sessionName, !sessionName.isEmpty { return sessionName }
        return projectName
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
