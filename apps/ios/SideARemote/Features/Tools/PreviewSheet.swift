import SideARemoteKit
import SwiftUI
import WebKit

/// Preview :port (section 4.14): the dev server through Side A's own listener, in a WebView held to
/// the Mac's pinned key and to the preview's own address. Closing it takes the preview down.
struct PreviewSheet: View {
    let port: SessionActions.Port
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var page: WebPage?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let page {
                    WebView(page)
                } else if let error {
                    ContentUnavailableView("Can't Preview", systemImage: "safari", description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
                if let page { bottomBar(page) }
            }
        }
        .task { await open() }
        .onDisappear {
            let tools = model.tools
            Task { await tools.endPreview(port.session, port: port.port) }
        }
    }

    private var title: String {
        if let title = page?.title, !title.isEmpty { return title }
        return "Preview"
    }

    @ToolbarContentBuilder private func bottomBar(_ page: WebPage) -> some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button("Back", systemImage: "chevron.backward") {
                if let item = page.backForwardList.backList.last { page.load(item) }
            }
            .disabled(page.backForwardList.backList.isEmpty)
            Button("Forward", systemImage: "chevron.forward") {
                if let item = page.backForwardList.forwardList.first { page.load(item) }
            }
            .disabled(page.backForwardList.forwardList.isEmpty)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Text(":\(String(port.port))")
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, Space.xs)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItemGroup(placement: .bottomBar) {
            Button("Reload", systemImage: "arrow.clockwise") { page.reload() }
            if let url = page.url { ShareLink(item: url) }
        }
    }

    /// A dev server is someone's code: nothing it stores outlives the sheet, no script reaches the app, and
    /// nothing on the page is filled in or detected for it.
    static var configuration: WebPage.Configuration {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = WKUserContentController()
        configuration.allowsInlinePredictions = false
        configuration.dataDetectorTypes = []
        configuration.allowsAirPlayForMediaPlayback = false
        return configuration
    }

    private func open() async {
        guard page == nil else { return }
        do {
            guard let pin = await model.tools.serverKeyHash() else { throw ToolError.demo }
            let url = try await model.tools.preview(port.session, port: port.port)
            let page = WebPage(configuration: Self.configuration, navigationDecider: PinnedNavigation(pin: pin, origin: url))
            page.load(URLRequest(url: url))
            self.page = page
        } catch {
            self.error = MacTools.message(error)
        }
    }
}

/// Every connection the preview makes is held to the key pinned at pairing, and every navigation to
/// the preview's own scheme, host and port: a link elsewhere stays put (Safari couldn't pin it). With
/// no ATS exception in the app, plain-HTTP subresources don't load either.
private struct PinnedNavigation: WebPage.NavigationDeciding {
    let pin: String
    let origin: URL

    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        // about:blank and blob: stay inside the page; file:, data: and every other origin don't load.
        if url.scheme == "about" || url.scheme == "blob" { return .allow }
        return url.scheme == origin.scheme && url.host() == origin.host() && url.port == origin.port ? .allow : .cancel
    }

    func decideAuthenticationChallengeDisposition(for challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.cancelAuthenticationChallenge, nil) }
        return PinnedTrust.hash(trust) == pin ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }
}
