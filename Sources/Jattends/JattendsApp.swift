import SwiftUI
import AppKit

@main
struct JattendsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let store = SessionStore()
    private var timer: Timer?
    private var lastHasWaiting = false

    private let normalIcon = MenuBarIcon.buildIcon(badge: false)
    private let badgeIcon = MenuBarIcon.buildIcon(badge: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = normalIcon
            button.action = #selector(togglePopover)
            button.target = self
        }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 300)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: SessionListView(sessions: [], waitingCount: 0)
        )
        self.popover = popover

        store.startWatching()

        // Poll store state to update icon
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

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Refresh content before showing
            popover.contentViewController = NSHostingController(
                rootView: SessionListView(
                    sessions: store.waitingSessions,
                    waitingCount: store.waitingCount
                )
            )
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
