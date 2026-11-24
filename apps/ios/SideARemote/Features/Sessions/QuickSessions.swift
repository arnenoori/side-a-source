import SideAProtocol
import SwiftUI

extension EnvironmentValues {
    @Entry var openSession: ((Route) -> Void)?
}

/// New Session's touch-and-hold menu. New Session comes last so it sits nearest the thumb.
struct QuickSessionsMenu: View {
    let newSession: () -> Void
    @Environment(AppRoot.self) private var root
    @Environment(\.openSession) private var openSession

    static let limit = 6

    var body: some View {
        let picks = Self.picks(root.macs)
        if !picks.isEmpty {
            Section {
                ForEach(picks, id: \.session.id) { pick in
                    let title = pick.mac.tools.title(for: pick.session)
                    let phase = SessionPhase(pick.session)
                    Button {
                        openSession?(.session(pick.session.id, mac: pick.mac.macID))
                    } label: {
                        Label { Text(title) } icon: { Image(uiImage: StatusGlyph.menuImage(phase)) }
                        Text(root.macs.count > 1 ? "\(pick.session.project) · \(pick.mac.mac.name)" : pick.session.project)
                    }
                    .accessibilityLabel("\(title), \(phase.title), \(pick.session.project)")
                }
            }
        }
        Section {
            Button("New Session", systemImage: "square.and.pencil", action: newSession)
        }
    }

    /// Every paired Mac, not only those the list shows: a shortcut shouldn't depend on the filter.
    static func picks(_ macs: [AppModel]) -> [(session: RemoteSession, mac: AppModel)] {
        let all = macs.flatMap { mac in mac.sessions.sessions.map { (session: $0, mac: mac) } }
        func rank(_ phase: SessionPhase) -> Int {
            switch phase {
            case .needsYou: 0
            case .ready: 1
            default: 2
            }
        }
        return Array(all.sorted { a, b in
            let ra = rank(SessionPhase(a.session)), rb = rank(SessionPhase(b.session))
            if ra != rb { return ra < rb }
            return (a.session.statusAt ?? 0) > (b.session.statusAt ?? 0)
        }.prefix(limit))
    }
}
