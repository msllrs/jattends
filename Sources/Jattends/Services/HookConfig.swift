import Foundation

/// Mirrors app preferences the hook needs into ~/.claude/jattends/config.json,
/// which the hook reads on every PermissionRequest.
enum HookConfig {
    static let defaultApprovalWaitSeconds = 45.0

    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/jattends/config.json")
    }

    static func sync() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "inAppApprovals") as? Bool ?? true
        let wait = defaults.object(forKey: "approvalWaitSeconds") as? Double
            ?? defaultApprovalWaitSeconds

        let config: [String: Any] = [
            "inAppApprovals": enabled,
            "approvalWaitSeconds": wait,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config) else { return }
        let tmp = configURL.appendingPathExtension("tmp")
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: tmp)
        try? FileManager.default.removeItem(at: configURL)
        try? FileManager.default.moveItem(at: tmp, to: configURL)
    }
}
