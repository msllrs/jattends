import SwiftUI

struct PreferencesView: View {
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("soundEnabled") private var soundEnabled = false
    @AppStorage("alertSoundName") private var alertSoundName = "Glass"
    @AppStorage("soundRepeat") private var soundRepeat = false
    @AppStorage("hotkeyEnabled") private var hotkeyEnabled = false
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = HotkeyManager.defaultKeyCode
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers = HotkeyManager.defaultModifiers

    @State private var isRecordingShortcut = false

    private let soundOptions = ["Glass", "Ping", "Pop", "Tink", "Blow", "Bottle", "Frog", "Hero", "Morse", "Purr", "Submarine"]

    var body: some View {
        VStack(spacing: 0) {
        Form {
            Section {
                Toggle("Enable notifications", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _, newValue in
                        if newValue {
                            NotificationManager.shared.requestPermission()
                        }
                    }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Show a macOS notification when a session needs attention.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Enable sound alert", isOn: $soundEnabled)
                Picker("Sound", selection: $alertSoundName) {
                    ForEach(soundOptions, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .disabled(!soundEnabled)

                Picker("Repeat", selection: $soundRepeat) {
                    Text("Once").tag(false)
                    Text("Until dismissed").tag(true)
                }
                .disabled(!soundEnabled)

                Button("Preview") {
                    NSSound(named: NSSound.Name(alertSoundName))?.play()
                }
                .disabled(!soundEnabled)
            } header: {
                Text("Sound")
            }

            Section {
                Toggle("Enable keyboard shortcut", isOn: $hotkeyEnabled)
                    .onChange(of: hotkeyEnabled) { _, newValue in
                        if newValue && hotkeyKeyCode == 0 {
                            hotkeyKeyCode = HotkeyManager.defaultKeyCode
                            hotkeyModifiers = HotkeyManager.defaultModifiers
                        }
                        HotkeyManager.shared.update()
                    }

                HStack {
                    Text("Shortcut:")
                    Spacer()
                    Button(isRecordingShortcut ? "Cancel" : "Record Shortcut") {
                        isRecordingShortcut.toggle()
                    }
                    if isRecordingShortcut {
                        Text("Press shortcut...")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    } else {
                        Text(shortcutLabel)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .disabled(!hotkeyEnabled)
            } header: {
                Text("Keyboard Shortcut")
            } footer: {
                Text("Jump to the most recent waiting session from any app.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        Spacer()
        HStack {
            Text("Jattends v1.0.0")
            Text("·")
            Link("@msllrs", destination: URL(string: "https://x.com/msllrs")!)
            Text("·")
            Link("GitHub", destination: URL(string: "https://github.com/msllrs/jattends")!)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.bottom, 12)
        }
        .frame(width: 420)
        .onKeyDown(enabled: isRecordingShortcut) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) != [] else { return }
            hotkeyKeyCode = Int(event.keyCode)
            hotkeyModifiers = Int(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
            isRecordingShortcut = false
            HotkeyManager.shared.update()
        }
    }

    private var shortcutLabel: String {
        if hotkeyKeyCode == 0 {
            return "None"
        }
        return HotkeyManager.shortcutDisplayString(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
    }
}

// MARK: - Key event capture modifier

private struct KeyDownModifier: ViewModifier {
    let enabled: Bool
    let handler: (NSEvent) -> Void

    func body(content: Content) -> some View {
        content.background(
            KeyDownCaptureView(enabled: enabled, handler: handler)
                .frame(width: 0, height: 0)
        )
    }
}

private struct KeyDownCaptureView: NSViewRepresentable {
    let enabled: Bool
    let handler: (NSEvent) -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.handler = handler
        view.isEnabled = enabled
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.handler = handler
        nsView.isEnabled = enabled
        if enabled {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

private class KeyCaptureNSView: NSView {
    var handler: ((NSEvent) -> Void)?
    var isEnabled = false

    override var acceptsFirstResponder: Bool { isEnabled }

    override func keyDown(with event: NSEvent) {
        if isEnabled {
            handler?(event)
        } else {
            super.keyDown(with: event)
        }
    }
}

private extension View {
    func onKeyDown(enabled: Bool, handler: @escaping (NSEvent) -> Void) -> some View {
        modifier(KeyDownModifier(enabled: enabled, handler: handler))
    }
}
