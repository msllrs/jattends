import SwiftUI

struct SessionRowView: View {
    let session: SessionInfo

    var body: some View {
        Button(action: { TerminalActivator.activate(session: session) }) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.projectName)
                        .font(.system(.body, weight: .medium))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(session.status.label)
                            .font(.caption)
                            .foregroundStyle(statusColor)

                        if let app = session.terminalApp, app != "unknown" {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(terminalDisplayName(app))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()

                if session.status == .waiting {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        switch session.status {
        case .waiting: return .orange
        case .active: return .green
        case .idle: return .secondary
        }
    }

    private func terminalDisplayName(_ termProgram: String) -> String {
        let names: [String: String] = [
            "ghostty": "Ghostty",
            "Apple_Terminal": "Terminal",
            "iTerm.app": "iTerm2",
            "iTerm2": "iTerm2",
            "kitty": "kitty",
            "WarpTerminal": "Warp",
            "vscode": "VS Code",
        ]
        return names[termProgram] ?? termProgram
    }
}
