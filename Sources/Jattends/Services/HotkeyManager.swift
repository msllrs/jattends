import AppKit

final class HotkeyManager {
    static let shared = HotkeyManager()

    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Called when the hotkey is pressed. Set by AppDelegate.
    var onHotkey: (() -> Void)?

    private init() {}

    /// Start listening for the configured global shortcut.
    func update() {
        stop()

        guard UserDefaults.standard.bool(forKey: "hotkeyEnabled") else { return }

        let keyCode = UInt16(UserDefaults.standard.integer(forKey: "hotkeyKeyCode"))
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(UserDefaults.standard.integer(forKey: "hotkeyModifiers")))

        guard keyCode != 0 else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == keyCode && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == modifiers {
                self?.onHotkey?()
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == keyCode && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == modifiers {
                self?.onHotkey?()
                return nil
            }
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    deinit {
        stop()
    }

    // MARK: - Shortcut display helpers

    /// Human-readable string for the current shortcut configuration.
    static func shortcutDisplayString(keyCode: Int, modifiers: Int) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        var parts: [String] = []
        if flags.contains(.control) { parts.append("\u{2303}") }
        if flags.contains(.option) { parts.append("\u{2325}") }
        if flags.contains(.shift) { parts.append("\u{21E7}") }
        if flags.contains(.command) { parts.append("\u{2318}") }

        let keyString = keyCodeToString(UInt16(keyCode))
        parts.append(keyString)
        return parts.joined()
    }

    static func keyCodeToString(_ keyCode: UInt16) -> String {
        // Common key codes
        let map: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 49: "Space", 50: "`",
            36: "\u{21A9}", 48: "\u{21E5}", 51: "\u{232B}", 53: "\u{238B}",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        ]
        return map[keyCode] ?? "Key\(keyCode)"
    }

    /// Default shortcut: Cmd+Shift+J
    static let defaultKeyCode = 38  // J
    static let defaultModifiers = Int(NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue)
}
