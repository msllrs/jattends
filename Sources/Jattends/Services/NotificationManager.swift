import Foundation
import UserNotifications
import AppKit

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private static let categoryIdentifier = "WAITING_SESSION"
    private static let focusActionIdentifier = "FOCUS_ACTION"
    private static let approvalCategoryIdentifier = "APPROVAL_REQUEST"
    private static let approveActionIdentifier = "APPROVE_ACTION"
    private static let denyActionIdentifier = "DENY_ACTION"

    private var onFocusSession: ((SessionInfo) -> Void)?
    private var onApprovalDecision: ((String, Bool) -> Void)?
    private var repeatTimer: Timer?
    private var repeatStartTime: Date?
    private var currentSound: NSSound?

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let focusAction = UNNotificationAction(
            identifier: Self.focusActionIdentifier,
            title: "Focus",
            options: .foreground
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [focusAction],
            intentIdentifiers: []
        )

        let approveAction = UNNotificationAction(
            identifier: Self.approveActionIdentifier,
            title: "Approve",
            options: []
        )
        let denyAction = UNNotificationAction(
            identifier: Self.denyActionIdentifier,
            title: "Deny",
            options: .destructive
        )
        let approvalCategory = UNNotificationCategory(
            identifier: Self.approvalCategoryIdentifier,
            actions: [approveAction, denyAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category, approvalCategory])
    }

    /// Set the callback for when a user taps the "Focus" action on a notification.
    func setFocusHandler(_ handler: @escaping (SessionInfo) -> Void) {
        onFocusSession = handler
    }

    /// Set the callback for Approve/Deny taps: (requestId, allow).
    func setApprovalHandler(_ handler: @escaping (String, Bool) -> Void) {
        onApprovalDecision = handler
    }

    /// Notify for a pending permission request with Approve/Deny actions.
    /// Sent regardless of the notificationsEnabled preference only when the
    /// in-app approvals feature itself is on — the hook is blocked waiting.
    func notifyApproval(_ request: ApprovalRequest) {
        let content = UNMutableNotificationContent()
        content.title = "\(request.projectName) — approve \(request.toolName)?"
        content.body = request.summary
        content.categoryIdentifier = Self.approvalCategoryIdentifier
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["requestId": request.requestId]

        let notification = UNNotificationRequest(
            identifier: "approval-\(request.requestId)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(notification)
    }

    /// Remove the notification for a request that was answered or expired.
    func withdrawApproval(requestId: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ["approval-\(requestId)"])
        center.removePendingNotificationRequests(withIdentifiers: ["approval-\(requestId)"])
    }

    /// Request notification permission from the user. Call when they enable notifications in prefs.
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                print("Notification permission error: \(error)")
            }
        }
    }

    /// Send notifications for newly waiting sessions.
    func notifyIfEnabled(sessions: [SessionInfo]) {
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled") else { return }

        for session in sessions {
            sendNotification(for: session)
        }
    }

    /// Play alert sound if enabled.
    func playSoundIfEnabled() {
        guard UserDefaults.standard.bool(forKey: "soundEnabled") else {
            stopRepeatingSound()
            return
        }
        playSound()

        if UserDefaults.standard.bool(forKey: "soundRepeat"), repeatTimer == nil {
            repeatStartTime = Date()
            let timeout = UserDefaults.standard.double(forKey: "soundRepeatTimeout")
            let maxDuration: TimeInterval = timeout > 0 ? timeout : 120 // default 2 minutes

            repeatTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                guard let self,
                      UserDefaults.standard.bool(forKey: "soundEnabled"),
                      UserDefaults.standard.bool(forKey: "soundRepeat") else {
                    self?.stopRepeatingSound()
                    return
                }
                // Auto-stop after timeout
                if let start = self.repeatStartTime, Date().timeIntervalSince(start) >= maxDuration {
                    self.stopRepeatingSound()
                    return
                }
                self.playSound()
            }
        }
    }

    /// Stop repeating sound (called when sessions are no longer waiting).
    func stopRepeatingSound() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatStartTime = nil
        currentSound?.stop()
        currentSound = nil
    }

    private func playSound() {
        let soundName = UserDefaults.standard.string(forKey: "alertSoundName") ?? "Glass"
        let sound = NSSound(named: NSSound.Name(soundName))
        currentSound = sound
        sound?.play()
    }

    private func sendNotification(for session: SessionInfo) {
        let content = UNMutableNotificationContent()
        content.title = "\(session.projectName) — \(session.status.label)"
        content.body = session.statusDetail ?? session.lastPrompt ?? "Needs attention"
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [
            "sessionId": session.sessionId,
            "cwd": session.cwd,
            "terminalApp": session.terminalApp ?? "",
            "terminalPid": session.terminalPid ?? 0,
            "terminalTty": session.terminalTty ?? ""
        ]

        let request = UNNotificationRequest(
            identifier: "waiting-\(session.sessionId)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.content.categoryIdentifier == Self.approvalCategoryIdentifier {
            if let requestId = response.notification.request.content.userInfo["requestId"] as? String {
                switch response.actionIdentifier {
                case Self.approveActionIdentifier:
                    DispatchQueue.main.async { [weak self] in
                        self?.onApprovalDecision?(requestId, true)
                    }
                case Self.denyActionIdentifier:
                    DispatchQueue.main.async { [weak self] in
                        self?.onApprovalDecision?(requestId, false)
                    }
                default:
                    break // default click: leave the request pending in the menu
                }
            }
            completionHandler()
            return
        }

        if response.actionIdentifier == Self.focusActionIdentifier ||
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let userInfo = response.notification.request.content.userInfo
            if let sessionId = userInfo["sessionId"] as? String,
               let cwd = userInfo["cwd"] as? String {
                let terminalApp = userInfo["terminalApp"] as? String
                let terminalPid = userInfo["terminalPid"] as? Int
                let terminalTty = userInfo["terminalTty"] as? String
                let session = SessionInfo(
                    sessionId: sessionId,
                    cwd: cwd,
                    status: .waiting,
                    terminalApp: terminalApp,
                    terminalPid: terminalPid != 0 ? terminalPid : nil,
                    terminalTty: (terminalTty?.isEmpty ?? true) ? nil : terminalTty,
                    claudePid: nil,
                    updatedAt: Date()
                )
                DispatchQueue.main.async { [weak self] in
                    self?.onFocusSession?(session)
                }
            }
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
