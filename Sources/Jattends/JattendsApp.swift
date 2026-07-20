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
    private var lastHasWaiting = false

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
        if UserDefaults.standard.object(forKey: "inAppApprovals") as? Bool ?? true {
            notificationManager.requestPermission()
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
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.scanForSessions()
            self?.store.refreshLiveCwds()
            self?.store.forceReload()
        }
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
        let current = store.hasWaiting || !approvalStore.pending.isEmpty
        if current != lastHasWaiting {
            lastHasWaiting = current
            statusItem.button?.image = current ? badgeIcon : normalIcon
        }

        // Notify for newly-waiting sessions
        let newSessions = store.consumeNewlyWaiting()
        if !newSessions.isEmpty {
            notificationManager.notifyIfEnabled(sessions: newSessions)
            notificationManager.playSoundIfEnabled()
        } else if !current {
            notificationManager.stopRepeatingSound()
        }
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
        // Delay slightly so the menu fully dismisses before we raise the terminal window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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
                detail: "Dismiss"
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
        let detail = session.statusDetail ?? (session.status.needsAttention ? session.status.label : nil)
        return Self.makeMenuItemTitle(
            symbol: Self.statusSymbols[session.status] ?? "○",
            color: Self.statusColors[session.status] ?? .secondaryLabelColor,
            title: session.projectName,
            detail: detail
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            TerminalActivator.activate(session: session)
        }
    }

    @objc private func clearAllSessions() {
        let sessionDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/jattends/sessions")
        if let files = try? FileManager.default.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    @objc private func dismissSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? SessionInfo else { return }
        let sessionFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/jattends/sessions/\(session.sessionId).json")
        try? FileManager.default.removeItem(at: sessionFile)
    }
}
