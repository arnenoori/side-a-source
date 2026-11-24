import SideAProtocol
import SwiftUI

/// The round New Session button: a tap opens the sheet, a hold opens `items`.
struct NewSessionMenuButton<Items: View>: View {
    var diameter: CGFloat = 48
    let hint: String
    @ViewBuilder var items: Items
    @Environment(KeyRequests.self) private var keys

    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: diameter * 0.38, weight: .medium))
                .frame(width: diameter, height: diameter)
                .contentShape(.circle)
                .hoverEffect(.highlight)
        } primaryAction: {
            keys.newSession += 1
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("New Session")
        .accessibilityHint(hint)
    }
}

/// New Session beside the phone's tab bar; its hold offers the folders used last.
struct ComposeButton: View {
    @Environment(AppRoot.self) private var root
    @Environment(AppModel.self) private var model
    @Environment(KeyRequests.self) private var keys

    static let inset: CGFloat = 21
    static let lift: CGFloat = -13

    private var recent: [RemoteProject] { model.tools.recentProjects.filter { $0.lastUsedAt != nil } }

    var body: some View {
        NewSessionMenuButton(diameter: 56, hint: recent.isEmpty ? "" : "Touch and hold for recent folders") {
            Section("New Session In") {
                ForEach(recent) { folder in
                    Button(folder.name, systemImage: "folder") {
                        root.newSession.project = folder
                        keys.newSession += 1
                    }
                }
            }
        }
        .foregroundStyle(.primary)
        .task(id: model.mac.shown == .live) {
            guard model.mac.shown == .live, model.tools.projects.isEmpty else { return }
            do { try await model.tools.loadProjects() } catch { return }
        }
    }
}
