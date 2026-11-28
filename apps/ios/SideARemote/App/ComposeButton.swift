import SideAProtocol
import SwiftUI

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

struct ComposeButton: View {
    @Environment(AppRoot.self) private var root
    @Environment(KeyRequests.self) private var keys
    /// The computer the list is showing: its folders, and where a folder picked here starts.
    private var model: AppModel { root.current }

    static let inset: CGFloat = 21
    static let lift: CGFloat = -13

    private var recent: [RemoteProject] { model.tools.recentProjects.filter { $0.lastUsedAt != nil } }

    var body: some View {
        HoldMenuButton(diameter: 56, label: "New Session", hint: recent.isEmpty ? "" : "Touch and hold for recent folders",
                       menuTitle: "New Session In", items: recent.map { HoldMenuButton.Item(id: $0.id, title: $0.name, symbol: "folder") },
                       primary: { keys.newSession += 1 },
                       pick: { id in
                           guard let folder = recent.first(where: { $0.id == id }) else { return }
                           root.newSession.macID = model.macID
                           root.newSession.project = folder
                           keys.newSession += 1
                       })
            .frame(width: 56, height: 56)
            .task(id: [model.macID, String(model.mac.shown == .live)]) {
                guard model.mac.shown == .live, model.tools.projects.isEmpty else { return }
                do { try await model.tools.loadProjects() } catch { return }
            }
    }
}

/// A round glass button whose tap runs `primary` and whose hold opens a menu: a UIKit button with a `menu` and without
/// `showsMenuAsPrimaryAction`, the system's own tap-or-hold control. A SwiftUI `Menu` with `primaryAction` under
/// `.glassEffect(.interactive())` puts the glass's press tracking in front of the menu's hold under a real finger.
struct HoldMenuButton: UIViewRepresentable {
    struct Item {
        let id: String
        let title: String
        let symbol: String
    }

    let diameter: CGFloat
    let label: String
    let hint: String
    let menuTitle: String
    let items: [Item]
    let primary: () -> Void
    let pick: (String) -> Void

    final class Coordinator {
        nonisolated deinit {}
        var primary: () -> Void = {}
        var pick: (String) -> Void = { _ in }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        var configuration = UIButton.Configuration.glass()
        configuration.image = UIImage(systemName: "square.and.pencil", withConfiguration: UIImage.SymbolConfiguration(pointSize: diameter * 0.38, weight: .medium))
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .label
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration)
        button.showsMenuAsPrimaryAction = false
        button.preferredMenuElementOrder = .fixed
        button.isPointerInteractionEnabled = true
        let coordinator = context.coordinator
        button.addAction(UIAction { _ in coordinator.primary() }, for: .primaryActionTriggered)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.primary = primary
        coordinator.pick = pick
        button.accessibilityLabel = label
        button.accessibilityHint = hint
        let actions = items.map { item in
            UIAction(title: item.title, image: UIImage(systemName: item.symbol)) { _ in coordinator.pick(item.id) }
        }
        button.menu = actions.isEmpty ? nil : UIMenu(title: menuTitle, children: actions)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: diameter, height: diameter)
    }
}
