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
    private var timer: Timer?
    private var lastHasWaiting = false

    private let normalIcon = MenuBarIcon.buildIcon(badge: false)
    private let badgeIcon = MenuBarIcon.buildIcon(badge: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = normalIcon
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Prompt for Accessibility permission if not already granted
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)

        store.startWatching()

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateIconIfNeeded()
        }
    }

    private func updateIconIfNeeded() {
        let current = store.hasWaiting
        if current != lastHasWaiting {
            lastHasWaiting = current
            statusItem.button?.image = current ? badgeIcon : normalIcon
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let sessions = store.waitingSessions

        if sessions.isEmpty {
            let item = NSMenuItem(title: "Nothing needs attention", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let header = NSMenuItem(title: "\(sessions.count) waiting", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            menu.addItem(NSMenuItem.separator())

            for session in sessions {
                let item = NSMenuItem(title: session.projectName, action: #selector(sessionClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = session

                // Color bar + project name
                let barColor: NSColor = session.status == .waiting
            ? NSColor(red: 0xd7/255, green: 0x77/255, blue: 0x57/255, alpha: 1)
            : .systemGreen
                item.attributedTitle = makeAttributedTitle(
                    bar: barColor,
                    name: session.projectName
                )

                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit Jattends", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func sessionClicked(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? SessionInfo else { return }
        // Delay slightly so the menu fully dismisses before we raise the terminal window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            TerminalActivator.activate(session: session)
        }
    }

    private func makeAttributedTitle(bar: NSColor, name: String) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let barAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: bar,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        ]
        result.append(NSAttributedString(string: "✱  ", attributes: barAttrs))

        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 13),
        ]
        result.append(NSAttributedString(string: name, attributes: nameAttrs))

        return result
    }
}
