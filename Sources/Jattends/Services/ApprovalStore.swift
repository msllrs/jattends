import Foundation

/// Watches the approvals directory for permission requests written by the
/// hook and writes decision files back for it to pick up.
@Observable
final class ApprovalStore {
    private(set) var pending: [ApprovalRequest] = []

    /// Called with requests that just appeared, for notifications.
    var onNewRequests: (([ApprovalRequest]) -> Void)?
    /// Called after every reload so the UI can refresh.
    var onReload: (() -> Void)?

    private var watcher: SessionDirectoryWatcher?
    private var knownIds: Set<String> = []

    private static let approvalsDirectory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/jattends/approvals")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func startWatching() {
        reload()
        watcher = SessionDirectoryWatcher(directory: Self.approvalsDirectory.path) { [weak self] in
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

    /// Answer a request. The hook polls for the decision file, forwards the
    /// decision to Claude Code, and deletes both files.
    func respond(to request: ApprovalRequest, allow: Bool) {
        let decision: [String: String] = allow
            ? ["behavior": "allow"]
            : ["behavior": "deny", "reason": "Denied from Jattends"]
        let url = Self.approvalsDirectory
            .appendingPathComponent("\(request.requestId).decision.json")
        let tmp = url.appendingPathExtension("tmp")
        if let data = try? JSONSerialization.data(withJSONObject: decision) {
            try? data.write(to: tmp)
            try? FileManager.default.moveItem(at: tmp, to: url)
        }
        pending.removeAll { $0.requestId == request.requestId }
        onReload?()
    }

    func reload() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.approvalsDirectory, includingPropertiesForKeys: nil)
        else {
            pending = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var requests: [ApprovalRequest] = []
        for file in files where file.pathExtension == "json" {
            if file.lastPathComponent.hasSuffix(".decision.json") {
                // Orphaned decision (the hook died before reading it)
                if let attrs = try? fm.attributesOfItem(atPath: file.path),
                   let modified = attrs[.modificationDate] as? Date,
                   Date().timeIntervalSince(modified) > 300 {
                    try? fm.removeItem(at: file)
                }
                continue
            }
            guard let data = try? Data(contentsOf: file),
                  let request = try? decoder.decode(ApprovalRequest.self, from: data)
            else { continue }
            if request.isExpired {
                try? fm.removeItem(at: file)
                continue
            }
            requests.append(request)
        }

        requests.sort { $0.createdAt < $1.createdAt }
        pending = requests

        let currentIds = Set(requests.map(\.requestId))
        let newIds = currentIds.subtracting(knownIds)
        knownIds = currentIds
        if !newIds.isEmpty {
            onNewRequests?(requests.filter { newIds.contains($0.requestId) })
        }
        onReload?()
    }
}
