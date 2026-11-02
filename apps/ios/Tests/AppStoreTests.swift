import XCTest
@testable import SideARemote

/// What App Store review reads from the bundle.
final class AppStoreTests: XCTestCase {
    private var bundles: [URL] {
        get throws {
            let app = Bundle.main.bundleURL
            let fm = FileManager.default
            let plugins = try fm.contentsOfDirectory(at: app.appendingPathComponent("PlugIns"), includingPropertiesForKeys: nil)
            let frameworks = (try? fm.contentsOfDirectory(at: app.appendingPathComponent("Frameworks"), includingPropertiesForKeys: nil)) ?? []
            // PlugIns also holds this test bundle while the tests run.
            return [app] + plugins.filter { $0.pathExtension == "appex" } + frameworks.filter { $0.lastPathComponent == "SideARemoteShared.framework" }
        }
    }

    func testEveryBundleHasAPrivacyManifest() throws {
        for bundle in try bundles {
            let url = bundle.appendingPathComponent("PrivacyInfo.xcprivacy")
            let manifest = try XCTUnwrap(NSDictionary(contentsOf: url), bundle.lastPathComponent)
            XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false, bundle.lastPathComponent)
        }
    }

    /// App Store Connect rejects an extension whose version or build differs from the app's; both come from project.yml.
    func testEveryBundleCarriesTheAppsVersion() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let version = try XCTUnwrap(info["CFBundleShortVersionString"] as? String)
        // XcodeGen writes a fixed 1.0 (1) unless project.yml names the settings; the simulator can read the sources.
        let config = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Config")
        for plist in try FileManager.default.contentsOfDirectory(at: config, includingPropertiesForKeys: nil) where plist.lastPathComponent.hasSuffix("-Info.plist") {
            let source = try XCTUnwrap(NSDictionary(contentsOf: plist), plist.lastPathComponent)
            XCTAssertEqual(source["CFBundleShortVersionString"] as? String, "$(MARKETING_VERSION)", plist.lastPathComponent)
            XCTAssertEqual(source["CFBundleVersion"] as? String, "$(CURRENT_PROJECT_VERSION)", plist.lastPathComponent)
        }
        for bundle in try bundles.dropFirst() {
            let other = try XCTUnwrap(Bundle(url: bundle)?.infoDictionary, bundle.lastPathComponent)
            XCTAssertEqual(other["CFBundleShortVersionString"] as? String, version, bundle.lastPathComponent)
            XCTAssertEqual(other["CFBundleVersion"] as? String, info["CFBundleVersion"] as? String, bundle.lastPathComponent)
        }
    }

    func testInfoForReview() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["ITSAppUsesNonExemptEncryption"] as? Bool, false)
        XCTAssertEqual(info["UIDeviceFamily"] as? [Int], [1])
        // Dictation is the keyboard's own; the app never opens the microphone.
        XCTAssertNil(info["NSMicrophoneUsageDescription"])
        XCTAssertNil(info["NSSpeechRecognitionUsageDescription"])
    }
}
