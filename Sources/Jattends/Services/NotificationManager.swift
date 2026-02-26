import Foundation
import UserNotifications
import AppKit

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private static let categoryIdentifier = "WAITING_SESSION"
    private static let focusActionIdentifier = "FOCUS_ACTION"

    private var onFocusSession: ((SessionInfo) -> Void)?
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
        center.setNotificationCategories([category])
    }

    /// Set the callback for when a user taps the "Focus" action on a notification.
    func setFocusHandler(_ handler: @escaping (SessionInfo) -> Void) {
        onFocusSession = handler
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
        content.title = "Jattends"
        content.body = "\(session.projectName) needs attention"
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [
            "sessionId": session.sessionId,
            "cwd": session.cwd,
            "terminalApp": session.terminalApp ?? "",
            "terminalPid": session.terminalPid ?? 0
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
        if response.actionIdentifier == Self.focusActionIdentifier ||
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let userInfo = response.notification.request.content.userInfo
            if let sessionId = userInfo["sessionId"] as? String,
               let cwd = userInfo["cwd"] as? String {
                let terminalApp = userInfo["terminalApp"] as? String
                let terminalPid = userInfo["terminalPid"] as? Int
                let session = SessionInfo(
                    sessionId: sessionId,
                    cwd: cwd,
                    status: .waiting,
                    terminalApp: terminalApp,
                    terminalPid: terminalPid != 0 ? terminalPid : nil,
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
