import SwiftUI
import AppKit

@main
struct JattendsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let store = SessionStore()
    private let approvalStore = ApprovalStore()
    private var dotUrgency: BadgeDotModel.Urgency?
    private var dotLayer: CALayer?
    private var dotGeneration = 0
    private var hooksHealthy = true
    private var hookWarningNotified = false

    private let normalIcon = MenuBarIcon.buildIcon(badge: false)
    private let badgeIcon = MenuBarIcon.buildIcon(badge: true)

    private let notificationManager = NotificationManager.shared
    private let hotkeyManager = HotkeyManager.shared
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = normalIcon
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Set up notification "Focus" action handler
        notificationManager.setFocusHandler { session in
            TerminalActivator.activate(session: session)
        }

        // Set up global hotkey action
        hotkeyManager.onHotkey = { [weak self] in
            self?.handleHotkey()
        }
        hotkeyManager.update()

        store.onReload = { [weak self] in
            self?.updateIconIfNeeded()
        }
        store.refreshLiveCwds()
        store.startWatching()

        // In-app approvals: mirror prefs for the hook, watch for its requests
        HookConfig.sync()
        notificationManager.setApprovalHandler { [weak self] requestId, allow in
            guard let self,
                  let request = self.approvalStore.pending.first(where: { $0.requestId == requestId })
            else { return }
            self.approvalStore.respond(to: request, allow: allow)
        }
        notificationManager.setApprovalFocusHandler { [weak self] sessionId in
            guard let session = self?.store.sessions.first(where: { $0.sessionId == sessionId })
            else { return }
            TerminalActivator.activate(session: session)
        }
        approvalStore.onNewRequests = { [weak self] requests in
            for request in requests {
                self?.notificationManager.notifyApproval(request)
            }
            self?.notificationManager.playSoundIfEnabled()
        }
        approvalStore.onReload = { [weak self] in
            self?.updateIconIfNeeded()
        }
        approvalStore.startWatching()
        if UserDefaults.standard.bool(forKey: "notificationsEnabled") {
            notificationManager.requestPermission()
        }

        // Programmatic activation channel: lets external tools (and tests)
        // trigger the same jump a menu click performs, by session id.
        // e.g. swift -e 'import Foundation; DistributedNotificationCenter.default()
        //   .postNotificationName(.init("com.jattends.activate"), object: "<sessionId>",
        //    userInfo: nil, deliverImmediately: true)'
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.jattends.activate"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let sessionId = note.object as? String,
                  let session = self?.store.sessions.first(where: { $0.sessionId == sessionId })
            else { return }
            TerminalActivator.activate(session: session)
        }

        // Force reload on wake from sleep — FSEvents can miss changes during sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.store.refreshLiveCwds()
            self?.store.forceReload()
        }

        // Safety-net periodic reload every 10s to catch missed FSEvents and clean dead PIDs
        // Also runs --scan to discover untracked claude processes
        scanForSessions()
        checkHookHealth()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.scanForSessions()
            self?.store.refreshLiveCwds()
            self?.store.forceReload()
            self?.checkHookHealth()
        }
    }

    /// Insurance against other tools rewriting ~/.claude/settings.json and
    /// silently stripping our hooks — the app would otherwise just go blind.
    private func checkHookHealth() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let hookPath = home.appendingPathComponent(".claude/hooks/jattends-hook.py").path

        var healthy = FileManager.default.isExecutableFile(atPath: hookPath)
        if healthy {
            let settingsURL = home.appendingPathComponent(".claude/settings.json")
            if let data = try? Data(contentsOf: settingsURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let hooks = json["hooks"] as? [String: Any] {
                for event in ["SessionStart", "Stop", "PermissionRequest"] {
                    let matchers = hooks[event] as? [[String: Any]] ?? []
                    let present = matchers.contains { matcher in
                        (matcher["hooks"] as? [[String: Any]] ?? []).contains {
                            ($0["command"] as? String ?? "").contains("jattends-hook")
                        }
                    }
                    if !present {
                        healthy = false
                        break
                    }
                }
            } else {
                healthy = false
            }
        }

        if !healthy && hooksHealthy && !hookWarningNotified {
            hookWarningNotified = true
            notificationManager.notifyHooksMissing()
        }
        if healthy {
            hookWarningNotified = false
        }
        hooksHealthy = healthy
    }

    private func scanForSessions() {
        let hookPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/hooks/jattends-hook.py").path
        guard FileManager.default.isExecutableFile(atPath: hookPath) else { return }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [hookPath, "--scan"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }

    private func updateIconIfNeeded() {
        let urgency: BadgeDotModel.Urgency?
        if !store.hasWaiting && approvalStore.pending.isEmpty {
            urgency = nil
        } else if !approvalStore.pending.isEmpty
            || store.waitingSessions.contains(where: { $0.status == .approval || $0.status == .error }) {
            urgency = .urgent
        } else {
            urgency = .normal
        }

        let action = BadgeDotModel.transition(from: dotUrgency, to: urgency)
        dotUrgency = urgency

        switch action {
        case .appear(let level):
            statusItem.button?.image = badgeIcon
            showDot(color: Self.dotColor(for: level))
        case .disappear:
            hideDot() // restores the normal icon once the dot is gone
        case .swap(let level):
            swapDotColor(to: Self.dotColor(for: level))
        case .none:
            break
        }

        // Notify for newly-waiting sessions
        let newSessions = store.consumeNewlyWaiting()
        if !newSessions.isEmpty {
            notificationManager.notifyIfEnabled(sessions: newSessions)
            notificationManager.playSoundIfEnabled()
        } else if urgency == nil {
            notificationManager.stopRepeatingSound()
        }
    }

    // MARK: - Animated badge dot (CALayer on the status button)

    private static func dotColor(for urgency: BadgeDotModel.Urgency) -> NSColor {
        switch urgency {
        case .urgent: return .systemRed
        case .normal: return Self.statusColors[.waiting] ?? .systemOrange
        }
    }

    private func showDot(color: NSColor) {
        dotGeneration += 1
        let dot = dotLayer ?? makeDotLayer()
        guard let dot else { return }
        dot.backgroundColor = color.cgColor

        // A leftover fillMode-forwards disappear animation would pin the
        // layer invisible if the dot is re-shown quickly.
        dot.removeAnimation(forKey: "dotDisappear")

        let appear = CABasicAnimation(keyPath: "transform.scale")
        appear.fromValue = 0.01
        appear.toValue = 1.0
        appear.duration = 0.15
        dot.add(appear, forKey: "dotAppear")
    }

    private func hideDot() {
        guard let dot = dotLayer else {
            statusItem.button?.image = normalIcon
            return
        }
        let disappear = CABasicAnimation(keyPath: "transform.scale")
        disappear.fromValue = 1.0
        disappear.toValue = 0.01
        disappear.duration = 0.12
        disappear.fillMode = .forwards
        disappear.isRemovedOnCompletion = false
        dot.add(disappear, forKey: "dotDisappear")

        dotGeneration += 1
        let expected = dotGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.dotGeneration == expected else { return }
            self.dotLayer?.removeFromSuperlayer()
            self.dotLayer = nil
            self.statusItem.button?.image = self.normalIcon
        }
    }

    private func swapDotColor(to color: NSColor) {
        guard let dot = dotLayer else { return }
        dot.backgroundColor = color.cgColor

        let scaleDown = CABasicAnimation(keyPath: "transform.scale")
        scaleDown.fromValue = 1.0
        scaleDown.toValue = 0.01
        scaleDown.duration = 0.1

        let scaleUp = CABasicAnimation(keyPath: "transform.scale")
        scaleUp.fromValue = 0.01
        scaleUp.toValue = 1.0
        scaleUp.duration = 0.15
        scaleUp.beginTime = 0.1

        let group = CAAnimationGroup()
        group.animations = [scaleDown, scaleUp]
        group.duration = 0.25
        dot.add(group, forKey: "dotSwap")
    }

    private func makeDotLayer() -> CALayer? {
        guard let button = statusItem.button else { return nil }
        button.wantsLayer = true
        guard let buttonLayer = button.layer else { return nil }

        let iconX = (button.bounds.width - MenuBarIcon.iconSize) / 2
        let iconY = (button.bounds.height - MenuBarIcon.iconSize) / 2

        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: MenuBarIcon.dotSize, height: MenuBarIcon.dotSize)
        // NSStatusBarButton is flipped but its layer geometry matches, so the
        // SVG's from-top Y applies directly
        layer.position = CGPoint(
            x: iconX + MenuBarIcon.dotCenter.x,
            y: iconY + MenuBarIcon.dotCenter.y
        )
        layer.cornerRadius = MenuBarIcon.dotSize / 2
        layer.masksToBounds = true
        buttonLayer.addSublayer(layer)
        dotLayer = layer
        return layer
    }

    private func handleHotkey() {
        if let session = store.waitingSessions.first {
            TerminalActivator.activate(session: session)
        } else {
            statusItem.button?.performClick(nil)
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !hooksHealthy {
            let warning = NSMenuItem(title: "Claude hooks missing", action: nil, keyEquivalent: "")
            warning.view = MenuRowView(text: Self.makeMenuItemTitle(
                symbol: "⚠︎",
                color: .systemYellow,
                title: "Claude hooks missing",
                detail: "Run scripts/install.sh to restore tracking"
            ))
            menu.addItem(warning)
            menu.addItem(NSMenuItem.separator())
        }

        let approvals = approvalStore.pending
        let waiting = store.waitingSessions
        let working = store.workingSessions
        let idle = store.idleSessions

        if approvals.isEmpty && waiting.isEmpty && working.isEmpty && idle.isEmpty {
            let item = NSMenuItem(title: "No Claude sessions", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if !approvals.isEmpty {
            let header = NSMenuItem(title: "Pending approvals", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for request in approvals {
                let item = NSMenuItem(title: request.projectName, action: nil, keyEquivalent: "")
                item.view = MenuRowView(text: makeApprovalTitle(for: request), showsChevron: true)

                let submenu = NSMenu()
                let approve = NSMenuItem(title: "Approve", action: #selector(approveRequest(_:)), keyEquivalent: "")
                approve.target = self
                approve.representedObject = request
                submenu.addItem(approve)

                let deny = NSMenuItem(title: "Deny", action: #selector(denyRequest(_:)), keyEquivalent: "")
                deny.target = self
                deny.representedObject = request
                submenu.addItem(deny)

                submenu.addItem(NSMenuItem.separator())
                let goTo = NSMenuItem(title: "Answer in Terminal", action: #selector(focusApprovalSession(_:)), keyEquivalent: "")
                goTo.target = self
                goTo.representedObject = request
                submenu.addItem(goTo)

                item.submenu = submenu
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
        }

        if !waiting.isEmpty {
            let header = NSMenuItem(title: "\(waiting.count) need\(waiting.count == 1 ? "s" : "") attention", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let clearAll = NSMenuItem(title: "Clear All", action: #selector(clearAllSessions), keyEquivalent: "")
            clearAll.target = self
            clearAll.isAlternate = true
            clearAll.keyEquivalentModifierMask = .option
            clearAll.view = MenuRowView(text: MenuRowView.plainTitle("Clear All"))
            menu.addItem(clearAll)

            addSessionItems(waiting, to: menu)
        }

        if !working.isEmpty {
            if !waiting.isEmpty { menu.addItem(NSMenuItem.separator()) }
            let header = NSMenuItem(title: "Working", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            addSessionItems(working, to: menu)
        }

        if !idle.isEmpty {
            if !waiting.isEmpty || !working.isEmpty { menu.addItem(NSMenuItem.separator()) }
            let header = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            addSessionItems(idle, to: menu)
        }

        menu.addItem(NSMenuItem.separator())

        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.view = MenuRowView(text: MenuRowView.plainTitle("Settings\u{2026}"), trailing: "⌘,")
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Jattends", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.view = MenuRowView(text: MenuRowView.plainTitle("Quit Jattends"), trailing: "⌘Q")
        menu.addItem(quit)
    }

    @objc private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = NSHostingView(rootView: PreferencesView())
        window.center()
        window.isReleasedWhenClosed = false
        self.settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func sessionClicked(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? SessionInfo else { return }
        // Next runloop pass: the menu window is already gone (dismissed
        // without animation), this just lets its teardown flush first
        DispatchQueue.main.async {
            TerminalActivator.activate(session: session)
        }
    }

    /// Add a click-to-focus item plus an Option-alternate dismiss item per session.
    private func addSessionItems(_ sessions: [SessionInfo], to menu: NSMenu) {
        for session in sessions {
            let item = NSMenuItem(title: session.projectName, action: #selector(sessionClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = session
            item.view = MenuRowView(text: makeAttributedTitle(for: session))
            menu.addItem(item)

            let alt = NSMenuItem(title: session.projectName, action: #selector(dismissSession(_:)), keyEquivalent: "")
            alt.target = self
            alt.representedObject = session
            alt.isAlternate = true
            alt.keyEquivalentModifierMask = .option
            alt.view = MenuRowView(text: Self.makeMenuItemTitle(
                symbol: "✕",
                color: .secondaryLabelColor,
                title: session.projectName,
                detail: "Hide until next activity"
            ))
            menu.addItem(alt)
        }
    }

    private static let statusColors: [SessionStatus: NSColor] = [
        .approval: .systemRed,
        .waiting: NSColor(red: 0xd7/255, green: 0x77/255, blue: 0x57/255, alpha: 1),
        .error: .systemRed,
        .working: .systemGreen,
        .compacting: .systemBlue,
        .idle: .tertiaryLabelColor,
    ]

    private static let statusSymbols: [SessionStatus: String] = [
        .approval: "✱", .waiting: "✱", .error: "✕",
        .working: "●", .compacting: "◐", .idle: "○",
    ]

    private func makeAttributedTitle(for session: SessionInfo) -> NSAttributedString {
        var parts: [String] = []

        // Elapsed turn time while Claude is actually going
        if session.status == .working || session.status == .compacting,
           let started = session.turnStartedAt {
            parts.append(SessionInfo.shortDuration(since: started))
        }

        if let count = session.subagentCount, count > 0 {
            parts.append("⑂ \(count) agent\(count == 1 ? "" : "s")")
        }

        // What it's doing; for attention, why; for idle, what it was about
        if let detail = session.statusDetail {
            parts.append(detail)
        } else if session.status.needsAttention {
            parts.append(session.status.label)
        } else if let prompt = session.lastPrompt {
            parts.append(prompt)
        }

        return Self.makeMenuItemTitle(
            symbol: Self.statusSymbols[session.status] ?? "○",
            color: Self.statusColors[session.status] ?? .secondaryLabelColor,
            title: session.projectName,
            detail: parts.isEmpty ? nil : parts.joined(separator: " · ")
        )
    }

    /// Two-line menu item title: the status symbol shares the title's line,
    /// and a tab stop puts the title and the detail line on the same left
    /// edge (spaces can't — the symbol and detail use different fonts).
    static func makeMenuItemTitle(
        symbol: String, color: NSColor, title: String, detail: String?
    ) -> NSAttributedString {
        let textColumn: CGFloat = 18
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: textColumn)]
        style.headIndent = textColumn

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "\(symbol)\t", attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .paragraphStyle: style,
        ]))
        result.append(NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor, // explicit — unset draws black, invisible in dark mode
            .paragraphStyle: style,
        ]))

        if let detail, !detail.isEmpty {
            result.append(NSAttributedString(string: "\n\t\(detail.prefix(60))", attributes: [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style,
            ]))
        }

        return result
    }

    private func makeApprovalTitle(for request: ApprovalRequest) -> NSAttributedString {
        Self.makeMenuItemTitle(
            symbol: "✱",
            color: .systemRed,
            title: request.projectName,
            detail: request.summary
        )
    }

    @objc private func approveRequest(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? ApprovalRequest else { return }
        approvalStore.respond(to: request, allow: true)
        notificationManager.withdrawApproval(requestId: request.requestId)
    }

    @objc private func denyRequest(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? ApprovalRequest else { return }
        approvalStore.respond(to: request, allow: false)
        notificationManager.withdrawApproval(requestId: request.requestId)
    }

    @objc private func focusApprovalSession(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? ApprovalRequest,
              let session = store.sessions.first(where: { $0.sessionId == request.sessionId })
        else { return }
        DispatchQueue.main.async {
            TerminalActivator.activate(session: session)
        }
    }

    @objc private func clearAllSessions() {
        store.dismissAll()
    }

    @objc private func dismissSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? SessionInfo else { return }
        store.dismiss(session)
    }
}
