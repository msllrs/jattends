import Foundation

/// opencode runs every session — TUI or `opencode run` — inside one
/// background service (`opencode serve --service`). Instead of hooks,
/// Jattends follows the service's authenticated SSE stream (/api/event)
/// and answers permissions over its HTTP API. Shapes here were verified
/// against opencode 2.0.25; parsing is deliberately tolerant because the
/// event vocabulary is undocumented and still moving.
private typealias JSON = [String: Any]

/// One opencode event Jattends cares about. Everything else on the stream
/// (text/reasoning deltas, registry updates, heartbeats) parses to nil.
enum OpencodeEvent: Equatable {
    enum Outcome: Equatable {
        case succeeded
        case interrupted
        case failed(message: String?)
    }

    case sessionCreated(sessionID: String, directory: String?)
    case executionStarted(sessionID: String)
    case executionEnded(sessionID: String, outcome: Outcome)
    case toolCalled(sessionID: String, detail: String?)
    case permissionAsked(OpencodePermission)
    case permissionResolved(sessionID: String, requestID: String)
    case formOpened(sessionID: String, formID: String, title: String?)
    case formClosed(sessionID: String, formID: String)
    case titleChanged(sessionID: String, title: String)
    case sessionDeleted(sessionID: String)

    var sessionID: String {
        switch self {
        case .sessionCreated(let id, _), .executionStarted(let id), .executionEnded(let id, _),
             .toolCalled(let id, _), .permissionResolved(let id, _), .formOpened(let id, _, _),
             .formClosed(let id, _), .titleChanged(let id, _), .sessionDeleted(let id):
            return id
        case .permissionAsked(let permission):
            return permission.sessionID
        }
    }

    /// Parse one SSE line. Nil for heartbeats (`: heartbeat`), blank
    /// separators, malformed JSON and event types we don't track.
    static func parse(sseLine: String) -> OpencodeEvent? {
        parseWithLocation(sseLine: sseLine)?.event
    }

    /// Like `parse(sseLine:)`, plus the event's top-level
    /// `location.directory`. Most session events carry one even when their
    /// data doesn't, and it's how a session first seen mid-run (Jattends
    /// started after it) learns its directory.
    static func parseWithLocation(sseLine: String) -> (event: OpencodeEvent, directory: String?)? {
        guard sseLine.hasPrefix("data:") else { return nil }
        let payload = sseLine.dropFirst("data:".count)
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? JSON,
              let type = object["type"] as? String
        else { return nil }
        let directory = Self.directory(in: object)
        guard let event = event(type: type, data: object["data"] as? JSON ?? [:], directory: directory)
        else { return nil }
        return (event, directory)
    }

    private static func event(type: String, data: JSON, directory: String?) -> OpencodeEvent? {
        guard let sessionID = nonEmpty(data["sessionID"]) else { return nil }
        switch type {
        case "session.created":
            return .sessionCreated(sessionID: sessionID, directory: Self.directory(in: data) ?? directory)
        case "session.execution.started":
            return .executionStarted(sessionID: sessionID)
        case "session.execution.succeeded", "session.idle":
            return .executionEnded(sessionID: sessionID, outcome: .succeeded)
        case "session.execution.interrupted":
            return .executionEnded(sessionID: sessionID, outcome: .interrupted)
        case "session.execution.failed", "session.error":
            return .executionEnded(sessionID: sessionID, outcome: .failed(message: failureMessage(data)))
        case "session.tool.called":
            return .toolCalled(sessionID: sessionID, detail: toolDetail(data["input"] as? JSON ?? [:]))
        case "permission.asked":
            return OpencodePermission(json: data, directory: directory).map(OpencodeEvent.permissionAsked)
        case "permission.replied", "permission.rejected":
            guard let requestID = nonEmpty(data["requestID"]) ?? nonEmpty(data["id"]) else { return nil }
            return .permissionResolved(sessionID: sessionID, requestID: requestID)
        case "form.created":
            guard let formID = nonEmpty(data["id"]) ?? nonEmpty(data["formID"]) else { return nil }
            return .formOpened(sessionID: sessionID, formID: formID, title: nonEmpty(data["title"]))
        case "form.replied", "form.cancelled":
            guard let formID = nonEmpty(data["formID"]) ?? nonEmpty(data["id"]) else { return nil }
            return .formClosed(sessionID: sessionID, formID: formID)
        // Titles are generated after the first turn and arrive as
        // session.renamed (seen live on 2.0.25); session.updated may also
        // carry one.
        case "session.updated", "session.renamed":
            guard let title = nonEmpty(data["title"]) else { return nil }
            return .titleChanged(sessionID: sessionID, title: title)
        case "session.deleted":
            return .sessionDeleted(sessionID: sessionID)
        default:
            return nil
        }
    }

    /// The failure payload's shape isn't confirmed: accept
    /// `error.message`, `error.data.message` (opencode's NamedError),
    /// a bare `message`, or `error` as a string.
    private static func failureMessage(_ data: JSON) -> String? {
        if let error = data["error"] as? JSON {
            if let message = nonEmpty(error["message"]) { return message }
            if let message = nonEmpty((error["data"] as? JSON)?["message"]) { return message }
        }
        return nonEmpty(data["message"]) ?? nonEmpty(data["error"])
    }

    /// Same verbs as the Claude Code hook's PostToolUse detail. Commands
    /// keep their first line only — the menu shows one line of detail.
    private static func toolDetail(_ input: JSON) -> String? {
        if let command = nonEmpty(input["command"]) {
            let firstLine = command.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
            return "Running: \(firstLine ?? command)"
        }
        if let path = nonEmpty(input["filePath"]) ?? nonEmpty(input["path"]) {
            return "Editing: \(URL(fileURLWithPath: path).lastPathComponent)"
        }
        return nil
    }

    fileprivate static func directory(in object: JSON) -> String? {
        nonEmpty((object["location"] as? JSON)?["directory"])
    }
}

private func nonEmpty(_ value: Any?) -> String? {
    guard let string = value as? String, !string.isEmpty else { return nil }
    return string
}

/// A pending opencode permission request (`permission.asked`).
struct OpencodePermission: Equatable {
    let id: String
    let sessionID: String
    /// opencode's permission kind: "shell", "edit", ...
    let action: String
    /// What the action touches: the command line, file paths, ...
    let resources: [String]
    let directory: String?

    init(id: String, sessionID: String, action: String, resources: [String], directory: String?) {
        self.id = id
        self.sessionID = sessionID
        self.action = action
        self.resources = resources
        self.directory = directory
    }

    /// From an event's or the pending list's item data. `fallbackDirectory`
    /// is the event's top-level location; an item's own location wins.
    fileprivate init?(json: JSON, directory fallbackDirectory: String?) {
        guard let id = nonEmpty(json["id"]), let sessionID = nonEmpty(json["sessionID"]) else { return nil }
        self.id = id
        self.sessionID = sessionID
        action = nonEmpty(json["action"]) ?? nonEmpty(json["permission"]) ?? "permission"
        resources = (json["resources"] as? [Any] ?? json["patterns"] as? [Any] ?? []).compactMap { $0 as? String }
        directory = OpencodeEvent.directory(in: json) ?? fallbackDirectory
    }

    /// Items of `GET /api/permission/request` → `{"data": [...]}`. Assumed
    /// to mirror permission.asked's data; anything unrecognisable is
    /// skipped. Nil when the body isn't that envelope at all, so a failed
    /// fetch can't be mistaken for "nothing pending".
    static func pendingList(from body: Data) -> [OpencodePermission]? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? JSON,
              let items = object["data"] as? [Any]
        else { return nil }
        return items.compactMap { ($0 as? JSON).flatMap { OpencodePermission(json: $0, directory: nil) } }
    }

    var summary: String { resources.joined(separator: ", ") }

    func approvalRequest(sessionName: String?, createdAt: Date) -> ApprovalRequest {
        ApprovalRequest(
            requestId: id,
            sessionId: sessionID,
            cwd: directory ?? "",
            sessionName: sessionName,
            toolName: action,
            summary: summary,
            createdAt: createdAt,
            agent: OpencodeClient.agentName)
    }
}

/// What Jattends knows about one opencode session, folded from events.
struct OpencodeSessionState: Equatable {
    let sessionID: String
    var directory: String
    /// Displayed status: the base status with any pending permission or
    /// form overlaid (see `resolve`).
    var status: SessionStatus = .idle
    var detail: String?
    var title: String?
    var updatedAt: Date
    var turnStartedAt: Date?
    /// Execution status, kept separately so overlays resolve back to it.
    var baseStatus: SessionStatus = .idle
    var baseDetail: String?
    var pendingPermissions: [String: OpencodePermission] = [:]
    /// Open questions (forms): formID → title.
    var openForms: [String: String] = [:]

    init(sessionID: String, directory: String, updatedAt: Date) {
        self.sessionID = sessionID
        self.directory = directory
        self.updatedAt = updatedAt
    }

    /// Fold one event into the session table. Events for a session never
    /// seen created (it predates the stream) create it on first sight.
    /// `directory` is the event's top-level location, when it had one.
    static func apply(_ event: OpencodeEvent, to all: inout [String: OpencodeSessionState],
                      at now: Date, directory: String? = nil) {
        let id = event.sessionID
        if case .sessionDeleted = event {
            all[id] = nil
            return
        }
        var state = all[id] ?? OpencodeSessionState(sessionID: id, directory: "", updatedAt: now)
        state.updatedAt = now
        if let directory, !directory.isEmpty { state.directory = directory }

        switch event {
        case .sessionCreated(_, let directory):
            if let directory, !directory.isEmpty { state.directory = directory }
        case .executionStarted:
            state.baseStatus = .working
            state.baseDetail = nil
            state.turnStartedAt = now
        case .toolCalled(_, let detail):
            state.baseStatus = .working
            state.baseDetail = detail
            if state.turnStartedAt == nil { state.turnStartedAt = now }
        case .executionEnded(_, let outcome):
            switch outcome {
            case .succeeded, .interrupted:
                state.baseStatus = .idle
                state.baseDetail = nil
            case .failed(let message):
                state.baseStatus = .error
                state.baseDetail = message
            }
            state.turnStartedAt = nil
            // A finished run can't still be blocked on the user; a
            // resolution event lost in a reconnect mustn't strand the row.
            state.pendingPermissions = [:]
            state.openForms = [:]
        case .permissionAsked(let permission):
            state.pendingPermissions[permission.id] = permission
            if let directory = permission.directory, !directory.isEmpty { state.directory = directory }
        case .permissionResolved(_, let requestID):
            state.pendingPermissions[requestID] = nil
        case .formOpened(_, let formID, let title):
            state.openForms[formID] = title ?? ""
        case .formClosed(_, let formID):
            state.openForms[formID] = nil
        case .titleChanged(_, let title):
            state.title = title
        case .sessionDeleted:
            break
        }
        state.resolve()
        all[id] = state
    }

    /// Replace pending permissions with the service's list (fetched at
    /// connect, covering requests asked while disconnected). Only requests
    /// in `replacing` — the ones known when the fetch was issued — may be
    /// dropped, so a live permission.asked that raced the fetch survives.
    static func reconcile(pending: [OpencodePermission], replacing known: Set<String>,
                          in all: inout [String: OpencodeSessionState], at now: Date) {
        let listed = Set(pending.map(\.id))
        for (id, var state) in all {
            let stale = state.pendingPermissions.keys.filter { known.contains($0) && !listed.contains($0) }
            guard !stale.isEmpty else { continue }
            for key in stale { state.pendingPermissions[key] = nil }
            state.resolve()
            all[id] = state
        }
        for permission in pending where all[permission.sessionID]?.pendingPermissions[permission.id] == nil {
            apply(.permissionAsked(permission), to: &all, at: now)
        }
    }

    /// Approval outranks a question, which outranks execution state. IDs
    /// sort by creation (opencode's are time-ordered), so the newest
    /// form's title is the one shown.
    private mutating func resolve() {
        if let permission = pendingPermissions.values.max(by: { $0.id < $1.id }) {
            status = .approval
            detail = permission.summary.isEmpty ? nil : permission.summary
        } else if let form = openForms.max(by: { $0.key < $1.key }) {
            status = .waiting
            detail = form.value.isEmpty ? nil : form.value
        } else {
            status = baseStatus
            detail = baseDetail
        }
    }

    func sessionInfo(terminal: OpencodeTerminal?) -> SessionInfo {
        SessionInfo(
            sessionId: sessionID,
            cwd: directory,
            status: status,
            sessionName: title,
            kind: "interactive",
            terminalApp: terminal?.app,
            // As for hook sessions, a Rex pane has no window pid: the
            // parent is the rex server daemon
            terminalPid: terminal?.app == "rex" ? nil : terminal?.appPid,
            terminalTty: terminal?.tty,
            rexBlock: terminal?.rexBlock,
            rexSession: terminal?.rexSession,
            claudePid: nil,
            updatedAt: updatedAt,
            statusDetail: detail,
            turnStartedAt: status == .working ? turnStartedAt : nil,
            agent: OpencodeClient.agentName)
    }
}

/// One `ps -eo pid,ppid,tty,comm` row. `tty` is nil for "??".
struct OpencodeProc: Equatable {
    let ppid: Int
    let tty: String?
    let comm: String

    /// Parse ps output keyed by pid. comm may hold spaces (app paths).
    static func parsePS(_ output: String) -> [Int: OpencodeProc] {
        var procs: [Int: OpencodeProc] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int(parts[0]), let ppid = Int(parts[1]) else { continue }
            let tty = String(parts[2])
            procs[pid] = OpencodeProc(
                ppid: ppid,
                tty: (tty == "??" || tty == "-") ? nil : tty,
                comm: parts[3].trimmingCharacters(in: .whitespaces))
        }
        return procs
    }

    /// Parse `lsof -a -d cwd -p <pids> -Fpn` output: `p<pid>` then `n<path>`.
    static func parseLsofCwds(_ output: String) -> [Int: String] {
        var cwds: [Int: String] = [:]
        var pid: Int?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int(line.dropFirst())
            } else if line.hasPrefix("n"), let current = pid {
                cwds[current] = String(line.dropFirst())
            }
        }
        return cwds
    }

    /// Rex pane IDs from `ps -wwE -o pid=,command= -p <pids>` (command
    /// line plus environment), keyed by pid. The output is space-joined,
    /// so only space-free values like the IDs can be recovered — not
    /// REX_BIN_DIR, which usually contains "Rex Beta.app".
    static func parseRexEnv(_ output: String) -> [Int: (block: String, session: String?)] {
        var result: [Int: (block: String, session: String?)] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = fields.first, let pid = Int(first) else { continue }
            func value(_ key: String) -> String? {
                fields.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
            }
            if let block = value("REX_BLOCK"), !block.isEmpty {
                result[pid] = (block, value("REX_SESSION"))
            }
        }
        return result
    }

    var name: String { URL(fileURLWithPath: comm).lastPathComponent }

    /// The opencode TUI: comm is the bare `opencode` and it owns a tty.
    /// The service child (full Cellar path) and stray daemons have no tty.
    var isOpencodeTUI: Bool { name == "opencode" && tty != nil }
}

/// The terminal an opencode TUI runs in, for focusing its window.
struct OpencodeTerminal: Equatable {
    /// The TUI process.
    let pid: Int
    let tty: String?
    /// TerminalActivator's terminalApp vocabulary (TERM_PROGRAM-style).
    let app: String?
    let appPid: Int?
    /// Rex pane hosting the TUI — Rex focuses by block, not window pid.
    var rexBlock: String? = nil
    var rexSession: String? = nil

    /// Same terminal set as the Claude Code hook's process walk (plus
    /// Rex), keyed by lowercased basename, mapped to the names
    /// TerminalActivator's appNameMap expects.
    private static let terminalApps: [String: String] = [
        "ghostty": "ghostty",
        "terminal": "Apple_Terminal",
        "iterm2": "iTerm2",
        "kitty": "kitty",
        "warp": "WarpTerminal",
        "stable": "WarpTerminal",
        "alacritty": "Alacritty",
        "wezterm": "WezTerm",
        "wezterm-gui": "WezTerm",
        "hyper": "Hyper",
        "code": "vscode",
        "electron": "vscode",
        "rex": "rex",
    ]

    /// The TUI whose cwd is `directory`, lowest pid first so repeated
    /// ticks pick the same one, with its terminal app found up the parent
    /// chain. Sessions don't record the TUI pid, so directory is the only
    /// link: two TUIs in one directory are indistinguishable.
    static func match(directory: String, procs: [Int: OpencodeProc], cwds: [Int: String]) -> OpencodeTerminal? {
        guard !directory.isEmpty,
              let pid = procs.filter({ $0.value.isOpencodeTUI && cwds[$0.key] == directory }).keys.min(),
              let tui = procs[pid]
        else { return nil }

        var app: String?
        var appPid: Int?
        var current = tui.ppid
        for _ in 0..<15 {
            guard current > 1, let proc = procs[current] else { break }
            if let mapped = terminalApps[proc.name.lowercased()] {
                app = mapped
                appPid = current
                break
            }
            current = proc.ppid
        }
        return OpencodeTerminal(pid: pid, tty: tui.tty.map { "/dev/" + $0 }, app: app, appPid: appPid)
    }
}

/// Service discovery, auth and request shapes for opencode's HTTP API.
enum OpencodeClient {
    static let agentName = "opencode"
    static let enabledKey = "opencodeEnabled"

    /// On unless the user turned it off in Settings — opencode needs no
    /// setup, so there's nothing to opt into.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The first URL `opencode service status` prints; nil when it reports
    /// anything else (not running, not installed as a service).
    static func serverURL(fromStatus output: String) -> URL? {
        output.split(whereSeparator: { $0.isWhitespace })
            .first { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
            .flatMap { URL(string: String($0)) }
    }

    /// The service takes HTTP Basic with the fixed user `opencode`; a
    /// Bearer token is rejected.
    static func authorizationHeader(password: String) -> String {
        "Basic " + Data("opencode:\(password)".utf8).base64EncodedString()
    }

    static func password(fromServiceJSON data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return nonEmpty(object["password"])
    }

    /// Jattends approves once, never "always": a standing rule belongs in
    /// opencode's own config, not behind a menu click.
    static func replyBody(allow: Bool) -> [String: String] {
        ["decision": allow ? "once" : "reject"]
    }

    static let serviceJSONURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/opencode/service.json")

    /// GUI apps get a bare PATH, so look where installers put opencode.
    static func executablePath(fileManager: FileManager = .default) -> String? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/opencode", "/usr/local/bin/opencode",
                          "\(home)/.opencode/bin/opencode", "\(home)/.local/bin/opencode"]
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Server URL and password, or nil when opencode or its service isn't
    /// there. Blocking (spawns the CLI): call off the main queue.
    static func resolveService() -> (url: URL, password: String)? {
        guard let exe = executablePath(),
              let output = run(exe, ["service", "status"], timeout: 5),
              let url = serverURL(fromStatus: output),
              let data = try? Data(contentsOf: serviceJSONURL),
              let password = password(fromServiceJSON: data)
        else { return nil }
        return (url, password)
    }

    /// Run a command, killing it after `timeout` so a wedged CLI can't
    /// stall the caller's queue forever.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
        // Read before waiting to avoid deadlock if output exceeds pipe buffer
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        return String(data: data, encoding: .utf8)
    }
}
