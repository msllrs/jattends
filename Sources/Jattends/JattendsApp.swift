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
        let current = store.hasWaiting
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

        let waiting = store.waitingSessions
        let working = store.workingSessions
        let idle = store.idleSessions

        if waiting.isEmpty && working.isEmpty && idle.isEmpty {
            let item = NSMenuItem(title: "No Claude sessions", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if !waiting.isEmpty {
            let header = NSMenuItem(title: "\(waiting.count) need\(waiting.count == 1 ? "s" : "") attention", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let clearAll = NSMenuItem(title: "Clear All", action: #selector(clearAllSessions), keyEquivalent: "")
            clearAll.target = self
            clearAll.isAlternate = true
            clearAll.keyEquivalentModifierMask = .option
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
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Jattends", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
            item.attributedTitle = makeAttributedTitle(for: session)
            menu.addItem(item)

            let alt = NSMenuItem(title: session.projectName, action: #selector(dismissSession(_:)), keyEquivalent: "")
            alt.target = self
            alt.representedObject = session
            alt.isAlternate = true
            alt.keyEquivalentModifierMask = .option
            alt.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Dismiss")
            alt.image?.size = NSSize(width: 14, height: 14)
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
        let result = NSMutableAttributedString()

        let symbol = Self.statusSymbols[session.status] ?? "○"
        let color = Self.statusColors[session.status] ?? .secondaryLabelColor
        result.append(NSAttributedString(string: "\(symbol)  ", attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        ]))

        result.append(NSAttributedString(string: session.projectName, attributes: [
            .font: NSFont.menuFont(ofSize: 13),
        ]))

        // Secondary line: what the session is doing / why it needs attention
        let detail = session.statusDetail ?? (session.status.needsAttention ? session.status.label : nil)
        if let detail, !detail.isEmpty {
            result.append(NSAttributedString(string: "\n    \(detail.prefix(60))", attributes: [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }

        return result
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
