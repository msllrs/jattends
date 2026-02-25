import SwiftUI

struct SessionListView: View {
    let sessions: [SessionInfo]
    let waitingCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Jattends")
                    .font(.system(.headline, weight: .semibold))
                Spacer()
                if waitingCount > 0 {
                    Text("\(waitingCount) waiting")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if sessions.isEmpty {
                EmptyStateView()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(sessions) { session in
                            SessionRowView(session: session)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 300)
            }

            Divider()

            // Footer
            Button(action: { NSApplication.shared.terminate(nil) }) {
                Text("Quit Jattends")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 280)
    }
}
