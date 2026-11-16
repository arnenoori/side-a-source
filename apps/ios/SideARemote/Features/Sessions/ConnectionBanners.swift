import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import SwiftUI

/// What the connection says in a list, as inset rows under the navigation bar: reconnecting, offline and why, pair
/// again, and a Mac that wants this iPhone paired again to approve things. Sessions and Accounts share it.
struct ConnectionBanners: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var pairingAgain = false

    var body: some View { banners }

    /// Under the navigation bar as an inset row, never a toast; the content below keeps its age.
    @ViewBuilder private var banners: some View {
        switch model.mac.state {
        case .reconnecting:
            // The chip says "Reconnecting…"; the row joins once the data is a minute old.
            if let age = Formatting.age(of: model.mac.lastSeen) {
                Section { BannerRow(symbol: "arrow.trianglehead.2.clockwise", text: "\(age) · Reconnecting…") }
            }
        case .offline(let reason) where reason.needsPairing:
            Section {
                BannerRow(symbol: reason == .keyChanged ? "key.slash" : "iphone.slash", text: reason.message(mac: model.mac.name),
                          age: Formatting.age(of: model.mac.lastSeen))
                Button("Pair Again", systemImage: "qrcode.viewfinder") { pairingAgain = true }
            }
            .pairAgain($pairingAgain, mac: model.mac.name)
        case .offline(let reason):
            Section {
                BannerRow(symbol: reason.symbol, text: reason.message(mac: model.mac.name),
                          age: Formatting.age(of: model.mac.lastSeen))
                if reason == .tailscaleOff {
                    Button("Open Tailscale", systemImage: "arrow.up.forward.app") { openURL(Tailscale.installed ? Tailscale.app : Tailscale.appStore) }
                }
                switch reason {
                case .appOutdated:
                    Button("Update in App Store", systemImage: "arrow.up.forward.app") { openURL(SideARemoteApp.appStore) }
                case .incompatible:
                    if let engine = model.link?.engine {
                        Button("Check Again", systemImage: "arrow.clockwise") { Task { await engine.reconnectNow() } }
                    }
                default:
                    if let link = model.link {
                        NavigationLink { TestConnectionView(link: link) } label: { Label("Test Connection", systemImage: "stethoscope") }
                    }
                }
                if reason.offersPairAgain {
                    Button("Pair Again", systemImage: "qrcode.viewfinder") { pairingAgain = true }
                }
            }
            .pairAgain($pairingAgain, mac: model.mac.name)
        case .live where model.tools.needsKeys:
            Section {
                BannerRow(symbol: "faceid", text: "Pair this iPhone again with \(model.mac.name) to approve, change settings or open the terminal from it.")
                Button("Pair Again", systemImage: "qrcode.viewfinder") { pairingAgain = true }
            }
            .pairAgain($pairingAgain, mac: model.mac.name)
        default:
            EmptyView()
        }
    }
}

/// A Mac whose Side A predates what this app version uses: the one row that says so, in place of features that just
/// aren't there. Sessions only, so it isn't repeated on every screen.
struct UpdateMacBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.mac.state == .live, model.tools.needsMacUpdate {
            Section { BannerRow(symbol: "arrow.down.circle", text: "Update Side A on \(model.mac.name)") }
        }
    }
}
