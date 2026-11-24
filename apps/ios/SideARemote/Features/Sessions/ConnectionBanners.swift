import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import SwiftUI

struct ConnectionBanners: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var pairingAgain = false

    var body: some View { banners }

    @ViewBuilder private var banners: some View {
        switch model.mac.shown {
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
                BannerRow(symbol: Biometry.current.symbol, text: "Pair this \(ThisDevice.kind) again with \(model.mac.name) to approve, change settings or open the terminal from it.")
                Button("Pair Again", systemImage: "qrcode.viewfinder") { pairingAgain = true }
            }
            .pairAgain($pairingAgain, mac: model.mac.name)
        default:
            EmptyView()
        }
    }
}

struct UpdateMacBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.mac.state == .live, model.tools.needsMacUpdate {
            Section { BannerRow(symbol: "arrow.down.circle", text: "Update Side A on \(model.mac.name)") }
        }
    }
}
