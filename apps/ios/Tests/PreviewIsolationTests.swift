import WebKit
import XCTest
@testable import SideARemote

@MainActor
final class PreviewIsolationTests: XCTestCase {
    /// Each preview sheet stores nothing past itself and shares nothing with another one (audit M5).
    func testEachPreviewGetsItsOwnEphemeralStore() {
        let first = PreviewSheet.configuration.websiteDataStore
        let second = PreviewSheet.configuration.websiteDataStore
        XCTAssertFalse(first.isPersistent)
        XCTAssertFalse(second.isPersistent)
        XCTAssertFalse(first === second)
        XCTAssertFalse(first === WKWebsiteDataStore.default())
    }

    /// No App Transport Security exception anywhere: the Mac is reached over pinned TLS on Network.framework, and a
    /// preview loads only from its own HTTPS origin (audit L6).
    func testNoTransportSecurityExceptions() throws {
        let app = Bundle.main.bundleURL
        let plugins = try FileManager.default.contentsOfDirectory(at: app.appendingPathComponent("PlugIns"), includingPropertiesForKeys: nil)
        for bundle in [app] + plugins {
            let info = try XCTUnwrap(Bundle(url: bundle)?.infoDictionary, bundle.lastPathComponent)
            XCTAssertNil(info["NSAppTransportSecurity"], bundle.lastPathComponent)
        }
    }
}
