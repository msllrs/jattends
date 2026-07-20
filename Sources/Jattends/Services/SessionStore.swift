import Foundation
import SwiftUI

@Observable
final class SessionStore {
    private(set) var sessions: [SessionInfo] = []
    private(set) var newlyWaitingSessions: [SessionInfo] = []

    /// Consume newly-attention-needing sessions so they aren't re-processed.
    func consumeNewlyWaiting() -> [SessionInfo] {
        let result = newlyWaitingSessions
        newlyWaitingSessions = []
        return result
    }
    private var watcher: SessionDirectoryWatcher?
    private var previousWaitingIds: Set<String> = []
    /// Cached live Claude cwds — refreshed periodically, not on every reload
    private var cachedLiveCwds: Set<String> = []
    /// Called after each reload so the UI can update immediately.
    var onReload: (() -> Void)?

    private static let sessionsDirectory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/jattends/sessions")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let dismissedDirectory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/jattends/dismissed")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Hide a session until its next activity: tombstone it so the process
    /// scan won't resurrect it, then remove its file. Any real hook event
    /// clears the tombstone and the session reappears.
    func dismiss(_ session: SessionInfo) {
        let fm = FileManager.default
        fm.createFile(atPath: Self.dismissedDirectory
            .appendingPathComponent("session-\(session.sessionId)").path, contents: nil)
        if let pid = session.claudePid {
            fm.createFile(atPath: Self.dismissedDirectory
                .appendingPathComponent("pid-\(pid)").path, contents: nil)
        }
        try? fm.removeItem(at: Self.sessionsDirectory
            .appendingPathComponent("\(session.sessionId).json"))
        forceReload()
    }

    func dismissAll() {
        for session in sessions {
            dismiss(session)
        }
    }

    /// Only sessions needing attention (approval, waiting, error).
    var waitingSessions: [SessionInfo] {
        sessions.filter { $0.status.needsAttention }
    }

    /// Sessions Claude is actively working in.
    var workingSessions: [SessionInfo] {
        sessions.filter { $0.status == .working || $0.status == .compacting }
    }

    /// Sessions with nothing happening.
    var idleSessions: [SessionInfo] {
        sessions.filter { $0.status == .idle }
    }

    var waitingCount: Int {
        waitingSessions.count
    }

    var hasWaiting: Bool {
        waitingCount > 0
    }

    func startWatching() {
        reload()

        let dir = Self.sessionsDirectory.path
        watcher = SessionDirectoryWatcher(directory: dir) { [weak self] in
            Task { @MainActor in
                self?.reload()
            }
        }
        watcher?.start()
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// Force a reload — called on wake from sleep and periodically as a safety net.
    func forceReload() {
        reload()
    }

    /// Refresh the cached set of live Claude cwds on a background thread.
    func refreshLiveCwds() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let cwds = self?.liveClaudeCwds() ?? []
            DispatchQueue.main.async {
                self?.cachedLiveCwds = cwds
            }
        }
    }

    /// Check if a process is still running.
    private func isProcessAlive(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0
    }

    /// Get cwds of all live `claude` processes via ps + lsof.
    private func liveClaudeCwds() -> Set<String> {
        var cwds = Set<String>()
        guard let psOutput = try? runCommand("/bin/ps", ["-eo", "pid,comm"]) else { return cwds }
        for line in psOutput.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[1].trimmingCharacters(in: .whitespaces) == "claude",
                  let pid = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            if let lsofOutput = try? runCommand("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", String(pid), "-Fn"]) {
                for lsofLine in lsofOutput.split(separator: "\n") {
                    if lsofLine.hasPrefix("n/") {
                        cwds.insert(String(lsofLine.dropFirst(1)))
                        break
                    }
                }
            }
        }
        return cwds
    }

    private func runCommand(_ path: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Read before waiting to avoid deadlock if output exceeds pipe buffer
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func reload() {
        let fm = FileManager.default
        let dir = Self.sessionsDirectory

        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" })
        else {
            sessions = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let autoClearMinutes = UserDefaults.standard.integer(forKey: "autoClearMinutes")
        let autoClearInterval: TimeInterval? = autoClearMinutes > 0 ? TimeInterval(autoClearMinutes * 60) : nil

        let liveCwds = cachedLiveCwds

        var loaded: [(URL, SessionInfo)] = []
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  var session = try? decoder.decode(SessionInfo.self, from: data)
            else {
                // Skip unreadable files (may be mid-write) — don't delete
                continue
            }
            // Normalize stale "working" to idle — hook events flow constantly
            // while Claude is genuinely active
            session.status = session.effectiveStatus
            if session.isStale {
                try? fm.removeItem(at: file)
                continue
            }
            // Remove sessions whose terminal process has died
            if let pid = session.terminalPid, !isProcessAlive(pid) {
                try? fm.removeItem(at: file)
                continue
            }
            // Remove sessions whose Claude process has died
            if let pid = session.claudePid, !isProcessAlive(pid) {
                try? fm.removeItem(at: file)
                continue
            }
            // Fallback for sessions without claudePid: check if any claude process owns this cwd
            if session.claudePid == nil, !liveCwds.contains(session.cwd) {
                try? fm.removeItem(at: file)
                continue
            }
            // Auto-clear attention-needing sessions past the configured timeout
            if let interval = autoClearInterval,
               session.status.needsAttention,
               Date().timeIntervalSince(session.updatedAt) > interval {
                try? fm.removeItem(at: file)
                continue
            }
            loaded.append((file, session))
        }

        // Deduplicate by claudePid: keep the most recently updated session per Claude process,
        // delete stale duplicates (from session reconnects that didn't fire SessionEnd)
        let (deduped, losers) = Self.dedupeByClaudePid(loaded)
        for file in losers {
            try? fm.removeItem(at: file)
        }

        sessions = Self.sorted(deduped)

        // Track sessions that just transitioned into needing attention
        let currentWaitingIds = Set(sessions.filter { $0.status.needsAttention }.map(\.sessionId))
        let newIds = currentWaitingIds.subtracting(previousWaitingIds)
        newlyWaitingSessions = sessions.filter { newIds.contains($0.sessionId) }
        previousWaitingIds = currentWaitingIds

        onReload?()
    }

    /// Keep the best session per Claude PID (higher-priority status wins,
    /// then most recent). Returns the surviving sessions and the files of
    /// the losers, which the caller deletes.
    static func dedupeByClaudePid(_ loaded: [(URL, SessionInfo)]) -> ([SessionInfo], [URL]) {
        var byClaudePid: [Int: (URL, SessionInfo)] = [:]
        var deduped: [SessionInfo] = []
        var losers: [URL] = []
        for (file, session) in loaded {
            guard let pid = session.claudePid else {
                deduped.append(session)
                continue
            }
            if let (existingFile, existing) = byClaudePid[pid] {
                let statusWins = existing.status < session.status
                let sameTied = existing.status == session.status && existing.updatedAt >= session.updatedAt
                if statusWins || sameTied {
                    losers.append(file)
                } else {
                    losers.append(existingFile)
                    byClaudePid[pid] = (file, session)
                }
            } else {
                byClaudePid[pid] = (file, session)
            }
        }
        deduped.append(contentsOf: byClaudePid.values.map(\.1))
        return (deduped, losers)
    }

    /// Drop sessions that already have a pending approval request — the
    /// approval row represents them with richer actions, so showing them
    /// again in a session group would duplicate the entry. Preserves order.
    static func hidingPendingApprovals(_ sessions: [SessionInfo], approvalSessionIds: Set<String>) -> [SessionInfo] {
        sessions.filter { !approvalSessionIds.contains($0.sessionId) }
    }

    /// Attention states first, then working, then idle; newest first within
    /// each group.
    static func sorted(_ sessions: [SessionInfo]) -> [SessionInfo] {
        sessions.sorted { a, b in
            if a.status != b.status { return a.status < b.status }
            return a.updatedAt > b.updatedAt
        }
    }
}
