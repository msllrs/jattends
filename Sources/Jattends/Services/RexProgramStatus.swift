import Foundation

/// One program status record from a Rex block. Claude Code reports its
/// pane state to Rex directly via OSC 7501, so for Rex sessions this is a
/// more immediate source than the hook-written session file.
struct RexStatusRecord: Codable, Equatable {
    struct Owner: Codable, Equatable {
        let pid: Int?
        let name: String?
    }

    let id: String?
    let state: String
    let kind: String?
    let app: String?
    let effectiveApp: String?
    /// Already decoded by Rex (the OSC carries it base64-encoded).
    let msg: String?
    let updatedAt: Date
    let owner: Owner?

    init(id: String?, state: String, kind: String?, app: String?, effectiveApp: String?,
         msg: String?, updatedAt: Date, owner: Owner?) {
        self.id = id
        self.state = state
        self.kind = kind
        self.app = app
        self.effectiveApp = effectiveApp
        self.msg = msg
        self.updatedAt = updatedAt
        self.owner = owner
    }

    private enum CodingKeys: String, CodingKey {
        case id, state, kind, app, msg, owner
        case effectiveApp = "effective_app"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        state = try c.decode(String.self, forKey: .state)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        app = try c.decodeIfPresent(String.self, forKey: .app)
        effectiveApp = try c.decodeIfPresent(String.self, forKey: .effectiveApp)
        msg = try c.decodeIfPresent(String.self, forKey: .msg)
        owner = try c.decodeIfPresent(Owner.self, forKey: .owner)
        // A record with no parseable time still counts; it just loses
        // every "newest" comparison.
        let stamp = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        updatedAt = stamp.flatMap(Self.parseDate) ?? .distantPast
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(app, forKey: .app)
        try c.encodeIfPresent(effectiveApp, forKey: .effectiveApp)
        try c.encodeIfPresent(msg, forKey: .msg)
        try c.encodeIfPresent(owner, forKey: .owner)
        try c.encode(Self.fractionalFormatter.string(from: updatedAt), forKey: .updatedAt)
    }

    /// Rex writes Go RFC 3339 timestamps: fractional seconds when nonzero,
    /// none otherwise — ISO8601DateFormatter accepts only one shape each.
    static func parseDate(_ string: String) -> Date? {
        fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainFormatter = ISO8601DateFormatter()
}

/// One line of watcher output.
enum RexStatusEvent: Equatable {
    case changed(block: String, record: RexStatusRecord)
    case removed(block: String, ids: [String])
}

/// Where Rex sessions take their status from (Settings → Rex).
enum RexStatusSource: String {
    /// Rex's program status records (OSC 7501 from Claude Code). Default.
    case programStatus
    /// The hook-written session file, as for every other terminal.
    case hooks

    static let defaultsKey = "rexStatusSource"

    /// Missing or unrecognised values mean the default, so a stale or
    /// hand-edited preference can't silently disable program status.
    static func current(_ defaults: UserDefaults = .standard) -> RexStatusSource {
        defaults.string(forKey: defaultsKey).flatMap(RexStatusSource.init(rawValue:)) ?? .programStatus
    }
}

enum RexProgramStatus {
    /// Lua run as `rex do -e <script> --all`: prints one JSON line per
    /// program status event, across every session (including later ones).
    /// The Lua has no JSON library, hence the tiny encoder. Its string
    /// escaper uses one gsub per step, each result bound to a fresh local:
    /// a single '[%c"\\]' class missed the quote under gopher-lua, and
    /// reassigning the parameter from a gsub crashes it.
    static let watcherScript = #"""
    local function str(v)
      local a = (v:gsub('\\', '\\\\'))
      local b = (a:gsub('"', '\\"'))
      local c = (b:gsub('%c', function(ch) return string.format("\\u%04x", ch:byte()) end))
      return '"' .. c .. '"'
    end
    local function enc(v)
      local t = type(v)
      if t == "table" then
        if #v > 0 then local p = {} for _, x in ipairs(v) do p[#p+1] = enc(x) end return "[" .. table.concat(p, ",") .. "]" end
        local p = {} for k, x in pairs(v) do p[#p+1] = str(tostring(k)) .. ":" .. enc(x) end return "{" .. table.concat(p, ",") .. "}"
      elseif t == "string" then
        return str(v)
      elseif t == "number" or t == "boolean" then return tostring(v) end
      return "null"
    end
    rex.on("com.superlogical.terminal.program_status_changed", function(_, ev)
      print(enc({type = "changed", block = ev.block_id, record = ev.payload.record}))
    end)
    rex.on("com.superlogical.terminal.program_status_removed", function(_, ev)
      print(enc({type = "removed", block = ev.block_id, ids = ev.payload.ids}))
    end)
    """#

    private struct EventLine: Decodable {
        let type: String
        let block: String
        let record: RexStatusRecord?
        let ids: LenientStrings?
    }

    /// The Lua encoder can't tell an empty array from an empty table, so
    /// `ids = {}` arrives as `{}`; treat any non-array as empty.
    private struct LenientStrings: Decodable {
        let values: [String]
        init(from decoder: Decoder) throws {
            values = (try? decoder.singleValueContainer().decode([String].self)) ?? []
        }
    }

    /// Parse one watcher stdout line. Nil for the "listening: ..." banner,
    /// partial output and unknown event types.
    static func parseEventLine(_ line: String) -> RexStatusEvent? {
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(EventLine.self, from: data)
        else { return nil }
        switch event.type {
        case "changed":
            guard let record = event.record else { return nil }
            return .changed(block: event.block, record: record)
        case "removed":
            return .removed(block: event.block, ids: event.ids?.values ?? [])
        default:
            return nil
        }
    }

    private struct Snapshot: Decodable {
        let records: [RexStatusRecord]?
    }

    /// Records from `rex block call -s S -b B program_status`. Empty for
    /// errors ("Error: ..."), which share the output with stdout.
    static func parseSnapshot(_ output: String) -> [RexStatusRecord] {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
              start < end,
              let data = String(output[start...end]).data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return [] }
        return snapshot.records ?? []
    }

    /// Map a record onto Jattends' status. Nil for states we don't know,
    /// so a newer Rex/Claude vocabulary falls back to the hook status
    /// rather than guessing.
    static func sessionStatus(for record: RexStatusRecord) -> SessionStatus? {
        switch record.state {
        case "working": return .working
        case "blocked": return record.kind == "permission" ? .approval : .waiting
        case "error": return .error
        case "idle", "done": return .idle
        default: return nil
        }
    }

    /// Whether Claude Code itself wrote the record (not a child program
    /// such as a build run under its Bash tool).
    private static func isClaude(_ record: RexStatusRecord) -> Bool {
        record.owner?.name == "claude" || record.app == "claude-code" || record.effectiveApp == "claude-code"
    }

    /// The record that speaks for the pane: Claude's own newest, else the
    /// newest of any program.
    static func preferredRecord(_ records: [RexStatusRecord]) -> RexStatusRecord? {
        let claude = records.filter(isClaude)
        return (claude.isEmpty ? records : claude).max { $0.updatedAt < $1.updatedAt }
    }

    /// Override Rex sessions' hook status with their block's program
    /// status. Sessions without a usable record keep the hook status, so
    /// older Claude Code builds (no OSC 7501) still work.
    static func applying(_ records: [String: [RexStatusRecord]], to sessions: [SessionInfo],
                         source: RexStatusSource) -> [SessionInfo] {
        guard source == .programStatus else { return sessions }
        return sessions.map { session in
            guard let block = session.rexBlock,
                  let record = preferredRecord(records[block] ?? []),
                  let status = sessionStatus(for: record)
            else { return session }
            var updated = session
            updated.status = status
            updated.statusDetail = (record.msg?.isEmpty ?? true) ? nil : record.msg
            return updated
        }
    }
}

/// Keeps Rex program status records current: a long-lived `rex do` watcher
/// streams changes, and a one-off snapshot per block covers state that
/// predates the watcher. All state lives on the main queue.
final class RexStatusMonitor {
    /// Called on the main queue whenever records change.
    var onChange: (() -> Void)?

    /// Records per block, for `RexProgramStatus.applying`.
    var records: [String: [RexStatusRecord]] {
        byBlock.mapValues { Array($0.values) }
    }

    private var byBlock: [String: [String: RexStatusRecord]] = [:]
    private var fetchedBlocks: Set<String> = []
    private var enabled = false
    private var process: Process?
    private var buffer = Data()
    private var startedAt = Date()
    private var restartDelay: TimeInterval = RexStatusMonitor.minRestartDelay
    private var restartScheduled = false
    /// The watcher hears every session, so any rex CLI will do; a session's
    /// own (from the hook) replaces the bundled path once one is seen.
    private var executable = TerminalActivator.rexBundledExecutable

    private static let minRestartDelay: TimeInterval = 5
    private static let maxRestartDelay: TimeInterval = 60

    var isRunning: Bool { process != nil }

    func start() {
        enabled = true
        launchWatcher()
    }

    func stop() {
        enabled = false
        if let process {
            self.process = nil
            process.terminationHandler = nil
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            process.terminate()
        }
        buffer = Data()
        let hadRecords = !byBlock.isEmpty
        byBlock = [:]
        fetchedBlocks = []
        if hadRecords { onChange?() }
    }

    /// Fetch the current records of Rex blocks not seen yet — once per
    /// block, so the periodic reload doesn't spawn a CLI per session per
    /// tick. Blocks whose session is gone are forgotten.
    func snapshot(_ sessions: [SessionInfo]) {
        guard enabled else { return }
        let rexSessions = sessions.filter { $0.rexBlock != nil && $0.rexSession != nil }
        let live = Set(rexSessions.compactMap(\.rexBlock))
        fetchedBlocks.formIntersection(live)
        let gone = byBlock.keys.filter { !live.contains($0) }
        if !gone.isEmpty {
            for block in gone { byBlock[block] = nil }
            onChange?()
        }

        if let session = rexSessions.first(where: { $0.rexBinDir?.isEmpty == false }) {
            executable = TerminalActivator.rexExecutable(for: session)
        }
        if process == nil && !restartScheduled { launchWatcher() }

        for session in rexSessions {
            guard let block = session.rexBlock, let rexSession = session.rexSession,
                  !fetchedBlocks.contains(block) else { continue }
            fetchedBlocks.insert(block)
            let exe = TerminalActivator.rexExecutable(for: session)
            guard FileManager.default.isExecutableFile(atPath: exe) else { continue }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = TerminalActivator.runRex(
                    exe, ["--autostart=false", "block", "call", "-s", rexSession, "-b", block, "program_status"])
                let snapshot = result.ok ? RexProgramStatus.parseSnapshot(result.output) : []
                DispatchQueue.main.async { self?.merge(snapshot, into: block) }
            }
        }
    }

    /// Snapshot records only fill gaps: a live event that landed while the
    /// call was in flight is newer and wins.
    private func merge(_ snapshot: [RexStatusRecord], into block: String) {
        guard enabled, !snapshot.isEmpty else { return }
        var changed = false
        for record in snapshot {
            let id = record.id ?? ""
            if let existing = byBlock[block]?[id], existing.updatedAt >= record.updatedAt { continue }
            byBlock[block, default: [:]][id] = record
            changed = true
        }
        if changed { onChange?() }
    }

    private func launchWatcher() {
        guard enabled, process == nil,
              FileManager.default.isExecutableFile(atPath: executable) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--autostart=false", "do", "-e", RexProgramStatus.watcherScript, "--all"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // EOF: stop polling; the termination handler does the cleanup
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { self?.receive(data, from: process) }
        }
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.watcherExited(proc) }
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            TerminalActivator.log("Rex status: watcher launch failed (\(error.localizedDescription))")
            scheduleRestart()
            return
        }
        self.process = process
        startedAt = Date()
    }

    private func receive(_ data: Data, from source: Process) {
        guard source === process, !data.isEmpty else { return }
        buffer.append(data)
        var changed = false
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8),
                  let event = RexProgramStatus.parseEventLine(line) else { continue }
            changed = apply(event) || changed
        }
        if changed { onChange?() }
    }

    private func apply(_ event: RexStatusEvent) -> Bool {
        switch event {
        case .changed(let block, let record):
            byBlock[block, default: [:]][record.id ?? ""] = record
            return true
        case .removed(let block, let ids):
            guard var blockRecords = byBlock[block] else { return false }
            for id in ids { blockRecords[id] = nil }
            byBlock[block] = blockRecords.isEmpty ? nil : blockRecords
            return true
        }
    }

    /// The watcher ends when the Rex server goes away (quit, update). Retry
    /// with growing backoff; a run that lasted resets it. Events may have
    /// been missed meanwhile, so blocks are re-snapshotted on next reload.
    private func watcherExited(_ proc: Process) {
        guard proc === process else { return }
        (proc.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        buffer = Data()
        fetchedBlocks = []
        TerminalActivator.log("Rex status: watcher exited (\(proc.terminationStatus))")
        if Date().timeIntervalSince(startedAt) > 30 { restartDelay = Self.minRestartDelay }
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard enabled, !restartScheduled else { return }
        restartScheduled = true
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, Self.maxRestartDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.restartScheduled = false
            self?.launchWatcher()
        }
    }
}
