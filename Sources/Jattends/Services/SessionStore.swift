import Foundation
import SwiftUI

@Observable
final class SessionStore {
    private(set) var sessions: [SessionInfo] = []
    private(set) var newlyWaitingSessions: [SessionInfo] = []

    /// Consume newly-waiting sessions so they aren't re-processed.
    func consumeNewlyWaiting() -> [SessionInfo] {
        let result = newlyWaitingSessions
        newlyWaitingSessions = []
        return result
    }
    private var watcher: SessionDirectoryWatcher?
    private var previousWaitingIds: Set<String> = []

    private static let sessionsDirectory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/jattends/sessions")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Only sessions needing attention.
    var waitingSessions: [SessionInfo] {
        sessions.filter { $0.status == .waiting }
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
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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

        // Build set of cwds with live claude processes (for legacy sessions without claudePid)
        let liveCwds = liveClaudeCwds()

        var loaded: [SessionInfo] = []
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let session = try? decoder.decode(SessionInfo.self, from: data)
            else {
                // Skip unreadable files (may be mid-write) — don't delete
                continue
            }
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
            // Auto-clear waiting sessions past the configured timeout
            if let interval = autoClearInterval,
               session.status == .waiting,
               Date().timeIntervalSince(session.updatedAt) > interval {
                try? fm.removeItem(at: file)
                continue
            }
            loaded.append(session)
        }

        // Sort: waiting first, then active, then idle; within each group sort by updatedAt descending
        sessions = loaded.sorted { a, b in
            if a.status != b.status { return a.status < b.status }
            return a.updatedAt > b.updatedAt
        }

        // Track newly-waiting sessions (those that just transitioned to waiting)
        let currentWaitingIds = Set(sessions.filter { $0.status == .waiting }.map(\.sessionId))
        let newIds = currentWaitingIds.subtracting(previousWaitingIds)
        newlyWaitingSessions = sessions.filter { newIds.contains($0.sessionId) }
        previousWaitingIds = currentWaitingIds
    }
}
