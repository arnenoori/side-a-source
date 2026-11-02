import SideAProtocol
import SwiftUI

/// Reply from the list (section 4.14): a short sheet with the field focused, for a session that has
/// finished its turn; the reply goes the way the composer's would.
struct ReplySheet: View {
    let sessionID: SessionKey
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var session: RemoteSession? { model.sessions.session(sessionID) }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Reply…", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused)
                } footer: {
                    if let reply = model.sessions.extras[sessionID]?.lastReply {
                        Text(reply).lineLimit(3)
                    }
                }
            }
            .navigationTitle("Reply")
            .navigationSubtitle(session.map { model.tools.title(for: $0) } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", systemImage: "arrow.up") {
                        model.reply(trimmed, to: sessionID)
                        dismiss()
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(trimmed.isEmpty)
                    .needsMac()
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.height(260), .medium])
        .presentationBackground(Color(.systemGroupedBackground))
    }
}
