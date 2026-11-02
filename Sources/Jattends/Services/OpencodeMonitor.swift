import Foundation

/// Follows opencode's background service: one long-lived SSE connection
/// (/api/event) carries every session's lifecycle, permissions and forms.
/// The service's port can change between runs, so each (re)connect
/// re-resolves it via `opencode service status`. All state lives on the
/// main queue; the URLSession delegate is called there too.
final class OpencodeMonitor {
    /// Called on the main queue (coalesced) whenever sessions or pending
    /// permissions change.
    var onChange: (() -> Void)?

    /// Sessions to show, bridged into Jattends' model.
    var sessions: [SessionInfo] {
        Self.visibleSessions(Array(states.values), terminal: terminal(for:), dismissed: dismissed, now: Date())
            .map { $0.sessionInfo(terminal: terminal(for: $0)) }
    }

    /// Every pending permission, oldest first.
    var pendingApprovals: [ApprovalRequest] {
        states.values
            .flatMap { state in
                state.pendingPermissions.values.map { permission in
                    var bridged = permission
                    if bridged.directory?.isEmpty ?? true, !state.directory.isEmpty {
                        bridged = OpencodePermission(id: permission.id, sessionID: permission.sessionID,
                                                     action: permission.action, resources: permission.resources,
                                                     directory: state.directory)
                    }
                    return bridged.approvalRequest(sessionName: state.title,
                                                   createdAt: askedAt[permission.id] ?? state.updatedAt)
                }
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private var states: [String: OpencodeSessionState] = [:]
    /// When each pending permission was first seen — the approval row's age.
    private var askedAt: [String: Date] = [:]
    /// Sessions hidden from the menu until their next event.
    private var dismissed: Set<String> = []
    /// Sessions whose title was already fetched (or is being).
    private var titleFetched: Set<String> = []
    private var procs: [Int: OpencodeProc] = [:]
    private var cwds: [Int: String] = [:]
    private var rexPanes: [Int: (block: String, session: String?)] = [:]

    private var enabled = false
    private var service: (url: URL, password: String)?
    private var urlSession: URLSession?
    private var streamTask: URLSessionDataTask?
    private var buffer = Data()
    private var connectedAt = Date()
    private var reconnectDelay = OpencodeMonitor.minReconnectDelay
    private var reconnectScheduled = false
    private var resolving = false
    private var changeScheduled = false
    private var refreshingTerminals = false

    private static let minReconnectDelay: TimeInterval = 2
    private static let maxReconnectDelay: TimeInterval = 60
    /// Sessions untouched this long are history, like stale session files.
    static let staleInterval: TimeInterval = 86400

    func start() {
        guard !enabled else { return }
        enabled = true
        reconnectDelay = Self.minReconnectDelay
        connect()
        refreshTerminals()
    }

    func stop() {
        enabled = false
        disconnect()
        service = nil
        let hadState = !states.isEmpty
        states = [:]
        askedAt = [:]
        dismissed = []
        titleFetched = []
        if hadState { notifyChange() }
    }

    /// Hide a session until its next event. Nothing is written anywhere:
    /// the service keeps the session; only this menu forgets it for now.
    func dismiss(sessionID: String) {
        guard states[sessionID] != nil else { return }
        dismissed.insert(sessionID)
        notifyChange()
    }

    /// Answer a permission. The row goes away immediately; if the POST
    /// fails, the pending list is re-fetched so the request comes back.
    func respond(requestID: String, sessionID: String, allow: Bool) {
        OpencodeSessionState.apply(.permissionResolved(sessionID: sessionID, requestID: requestID),
                                   to: &states, at: Date())
        askedAt[requestID] = nil
        notifyChange()

        guard let service,
              let url = Self.url(service.url, path: "/api/session/\(sessionID)/permission/\(requestID)/reply")
        else { return }
        var request = Self.request(url, password: service.password)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: OpencodeClient.replyBody(allow: allow))
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error != nil || !(200..<300).contains(status) else { return }
            DispatchQueue.main.async {
                TerminalActivator.log("opencode: permission reply failed (\(status) \(error?.localizedDescription ?? ""))")
                self?.seedPendingPermissions()
            }
        }.resume()
    }

    /// Re-match sessions to TUI terminals — called on the app's periodic
    /// tick. ps + lsof run off the main queue.
    func refreshTerminals() {
        guard enabled, !refreshingTerminals else { return }
        refreshingTerminals = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let procs = OpencodeProc.parsePS(OpencodeClient.run("/bin/ps", ["-eo", "pid,ppid,tty,comm"], timeout: 5) ?? "")
            let tuiPids = procs.filter { $0.value.isOpencodeTUI }.keys.map(String.init)
            var cwds: [Int: String] = [:]
            var rexPanes: [Int: (block: String, session: String?)] = [:]
            if !tuiPids.isEmpty {
                let pidList = tuiPids.joined(separator: ",")
                if let output = OpencodeClient.run(
                    "/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", pidList, "-Fpn"], timeout: 5) {
                    cwds = OpencodeProc.parseLsofCwds(output)
                }
                if let output = OpencodeClient.run(
                    "/bin/ps", ["-wwE", "-o", "pid=,command=", "-p", pidList], timeout: 5) {
                    rexPanes = OpencodeProc.parseRexEnv(output)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshingTerminals = false
                let changed = procs != self.procs || cwds != self.cwds
                    || rexPanes.mapValues(\.block) != self.rexPanes.mapValues(\.block)
                self.procs = procs
                self.cwds = cwds
                self.rexPanes = rexPanes
                if changed { self.notifyChange() }
            }
        }
    }

    // MARK: - Visibility

    /// Which sessions get a row. The service also hosts finished
    /// `opencode run` sessions and every past TUI session, so an idle
    /// session shows only while a TUI is open on its directory, and only
    /// the newest session per TUI (the one it's showing). Working and
    /// attention sessions always show; anything untouched for a day or
    /// dismissed is hidden.
    static func visibleSessions(_ states: [OpencodeSessionState],
                                terminal: (OpencodeSessionState) -> OpencodeTerminal?,
                                dismissed: Set<String>, now: Date) -> [OpencodeSessionState] {
        let live = states.filter {
            !dismissed.contains($0.sessionID) && now.timeIntervalSince($0.updatedAt) <= staleInterval
        }
        var newestPerTUI: [Int: OpencodeSessionState] = [:]
        for state in live {
            guard let pid = terminal(state)?.pid else { continue }
            if let existing = newestPerTUI[pid], existing.updatedAt >= state.updatedAt { continue }
            newestPerTUI[pid] = state
        }
        return live.filter { state in
            if state.status != .idle { return true }
            guard let pid = terminal(state)?.pid else { return false }
            return newestPerTUI[pid]?.sessionID == state.sessionID
        }
    }

    private func terminal(for state: OpencodeSessionState) -> OpencodeTerminal? {
        guard var terminal = OpencodeTerminal.match(directory: state.directory, procs: procs, cwds: cwds)
        else { return nil }
        if let pane = rexPanes[terminal.pid] {
            terminal.rexBlock = pane.block
            terminal.rexSession = pane.session
        }
        return terminal
    }

    // MARK: - Connection

    private func connect() {
        guard enabled, !resolving, streamTask == nil else { return }
        resolving = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let service = OpencodeClient.resolveService()
            DispatchQueue.main.async { self?.resolved(service) }
        }
    }

    private func resolved(_ service: (url: URL, password: String)?) {
        resolving = false
        guard enabled else { return }
        guard let service, let url = Self.url(service.url, path: "/api/event") else {
            // No service means no sessions: whatever we held is gone
            self.service = nil
            if !states.isEmpty {
                states = [:]
                askedAt = [:]
                notifyChange()
            }
            scheduleReconnect()
            return
        }
        self.service = service

        let delegate = StreamDelegate(
            onResponse: { [weak self] task, response in self?.streamResponded(task, response) },
            onData: { [weak self] task, data in self?.receive(data, from: task) },
            onComplete: { [weak self] task, error in self?.streamEnded(task, error) })
        let config = URLSessionConfiguration.default
        // Heartbeats arrive well within this; silence this long means the
        // connection is dead even if the socket never closed.
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = .infinity
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: .main)
        var request = Self.request(url, password: service.password)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        urlSession = session
        streamTask = task
        buffer = Data()
        connectedAt = Date()
        task.resume()
    }

    private func disconnect() {
        streamTask?.cancel()
        streamTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        buffer = Data()
    }

    private func streamResponded(_ task: URLSessionDataTask, _ response: URLResponse) {
        guard task === streamTask else { return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            TerminalActivator.log("opencode: event stream refused (\(status))")
            task.cancel()
            return
        }
        seedSessions()
        seedPendingPermissions()
    }

    private func streamEnded(_ task: URLSessionTask, _ error: Error?) {
        guard task === streamTask else { return }
        TerminalActivator.log("opencode: event stream ended (\(error?.localizedDescription ?? "closed"))")
        disconnect()
        if Date().timeIntervalSince(connectedAt) > 30 { reconnectDelay = Self.minReconnectDelay }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard enabled, !reconnectScheduled else { return }
        reconnectScheduled = true
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, Self.maxReconnectDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.reconnectScheduled = false
            self?.connect()
        }
    }

    private func receive(_ data: Data, from task: URLSessionDataTask) {
        guard task === streamTask else { return }
        buffer.append(data)
        var changed = false
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard var line = String(data: lineData, encoding: .utf8) else { continue }
            if line.hasSuffix("\r") { line.removeLast() }
            guard let (event, directory) = OpencodeEvent.parseWithLocation(sseLine: line) else { continue }
            apply(event, directory: directory)
            changed = true
        }
        if changed { notifyChange() }
    }

    private func apply(_ event: OpencodeEvent, directory: String?) {
        let id = event.sessionID
        let now = Date()
        dismissed.remove(id)
        OpencodeSessionState.apply(event, to: &states, at: now, directory: directory)
        switch event {
        case .permissionAsked(let permission):
            if askedAt[permission.id] == nil { askedAt[permission.id] = now }
        case .sessionDeleted:
            titleFetched.remove(id)
        case .sessionCreated:
            // A new TUI session should match its terminal without waiting
            // for the next tick
            refreshTerminals()
        default:
            break
        }
        pruneAskedAt()
        fetchTitleIfNeeded(id)
    }

    private func pruneAskedAt() {
        let pending = Set(states.values.flatMap { $0.pendingPermissions.keys })
        askedAt = askedAt.filter { pending.contains($0.key) }
    }

    // MARK: - Requests

    /// Fetch pending permissions — at connect, for requests asked while
    /// Jattends wasn't listening, and after a failed reply.
    private func seedPendingPermissions() {
        guard let service, let url = Self.url(service.url, path: "/api/permission/request") else { return }
        let known = Set(states.values.flatMap { $0.pendingPermissions.keys })
        URLSession.shared.dataTask(with: Self.request(url, password: service.password)) { [weak self] data, _, _ in
            guard let data, let pending = OpencodePermission.pendingList(from: data) else { return }
            DispatchQueue.main.async {
                guard let self, self.enabled else { return }
                let now = Date()
                OpencodeSessionState.reconcile(pending: pending, replacing: known, in: &self.states, at: now)
                for permission in pending where self.askedAt[permission.id] == nil {
                    self.askedAt[permission.id] = now
                }
                self.pruneAskedAt()
                for permission in pending { self.fetchTitleIfNeeded(permission.sessionID) }
                self.notifyChange()
            }
        }.resume()
    }

    /// Sessions that predate the stream, so an idle TUI shows up at launch
    /// rather than on its next turn. Seeded as idle: a running one turns
    /// working on its next tool call. Known sessions are left alone —
    /// their live state is newer.
    private func seedSessions() {
        guard let service, let url = Self.url(service.url, path: "/api/session") else { return }
        URLSession.shared.dataTask(with: Self.request(url, password: service.password)) { [weak self] data, _, _ in
            guard let data else { return }
            let summaries = Self.sessionList(from: data)
            DispatchQueue.main.async {
                guard let self, self.enabled else { return }
                let now = Date()
                var changed = false
                for summary in summaries where self.states[summary.id] == nil
                    && now.timeIntervalSince(summary.updatedAt) <= Self.staleInterval {
                    var state = OpencodeSessionState(sessionID: summary.id, directory: summary.directory ?? "",
                                                     updatedAt: summary.updatedAt)
                    state.title = summary.title
                    self.states[summary.id] = state
                    self.titleFetched.insert(summary.id)
                    changed = true
                }
                if changed { self.notifyChange() }
            }
        }.resume()
    }

    /// `GET /api/session` → `{"data": [session...]}`; `time.updated` is
    /// epoch milliseconds. Sessions without it are skipped (age unknown).
    static func sessionList(from body: Data) -> [(id: String, title: String?, directory: String?, updatedAt: Date)] {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let items = object["data"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty,
                  let updated = (item["time"] as? [String: Any])?["updated"] as? Double
            else { return nil }
            let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let directory = ((item["location"] as? [String: Any])?["directory"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            return (id, title, directory, Date(timeIntervalSince1970: updated / 1000))
        }
    }

    private func fetchTitleIfNeeded(_ sessionID: String) {
        guard let state = states[sessionID], state.title == nil, !titleFetched.contains(sessionID) else { return }
        titleFetched.insert(sessionID)
        fetchSession(sessionID)
    }

    /// One GET per newly seen session for its title (and directory, for a
    /// session first seen mid-run). Titles generated later arrive as
    /// session.renamed events.
    private func fetchSession(_ sessionID: String) {
        guard let service, let url = Self.url(service.url, path: "/api/session/\(sessionID)") else { return }
        URLSession.shared.dataTask(with: Self.request(url, password: service.password)) { [weak self] data, _, _ in
            guard let data, let info = Self.sessionSummary(from: data) else { return }
            DispatchQueue.main.async {
                guard let self, var state = self.states[sessionID] else { return }
                var changed = false
                if state.title == nil, let title = info.title {
                    state.title = title
                    changed = true
                }
                if state.directory.isEmpty, let directory = info.directory {
                    state.directory = directory
                    changed = true
                }
                guard changed else { return }
                self.states[sessionID] = state
                self.notifyChange()
            }
        }.resume()
    }

    /// Title and directory from `GET /api/session/{id}` — `{"data": {...}}`
    /// on 2.0.25; a bare session object is accepted too.
    static func sessionSummary(from body: Data) -> (title: String?, directory: String?)? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let session = object["data"] as? [String: Any] ?? object
        let title = (session["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let directory = ((session["location"] as? [String: Any])?["directory"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        return (title, directory)
    }

    private static func url(_ base: URL, path: String) -> URL? {
        URL(string: path, relativeTo: base)?.absoluteURL
    }

    private static func request(_ url: URL, password: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(OpencodeClient.authorizationHeader(password: password), forHTTPHeaderField: "Authorization")
        return request
    }

    /// Token deltas don't reach here, but tool calls can still come in
    /// bursts; one store reload per runloop pass is plenty.
    private func notifyChange() {
        guard !changeScheduled else { return }
        changeScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.changeScheduled = false
            self?.onChange?()
        }
    }
}

/// URLSession retains its delegate until invalidated; keeping the delegate
/// separate (closures holding the monitor weakly) avoids a retain cycle.
private final class StreamDelegate: NSObject, URLSessionDataDelegate {
    let onResponse: (URLSessionDataTask, URLResponse) -> Void
    let onData: (URLSessionDataTask, Data) -> Void
    let onComplete: (URLSessionTask, Error?) -> Void

    init(onResponse: @escaping (URLSessionDataTask, URLResponse) -> Void,
         onData: @escaping (URLSessionDataTask, Data) -> Void,
         onComplete: @escaping (URLSessionTask, Error?) -> Void) {
        self.onResponse = onResponse
        self.onData = onData
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        onResponse(dataTask, response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        onData(dataTask, data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onComplete(task, error)
    }
}
