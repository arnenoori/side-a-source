import UIKit
import XCTest
@testable import SideARemote

@MainActor
final class AppIconTests: XCTestCase {
    func testEveryOptionHasItsArtAtASizeThatStaysSharpAt120Points() throws {
        for option in AppIconOption.allCases {
            let image = try XCTUnwrap(UIImage(named: option.art), "\(option.name) has no art")
            XCTAssertGreaterThanOrEqual(image.size.width * image.scale, 360, "\(option.name) art is too small")
        }
    }

    func testTheDefaultIsNoAlternateAndTheRestAreDeclaredInTheBundle() throws {
        XCTAssertNil(AppIconOption.standard.iconName)
        let icons = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let alternates = try XCTUnwrap(icons["CFBundleAlternateIcons"] as? [String: Any])
        for option in AppIconOption.allCases where option != .standard {
            XCTAssertNotNil(alternates[try XCTUnwrap(option.iconName)], "\(option.name) is not in CFBundleAlternateIcons")
        }
    }

    func testTheNameiOSReportsMapsBackAndAnUnknownOneIsTheDefault() {
        for option in AppIconOption.allCases { XCTAssertEqual(AppIconOption(iconName: option.iconName), option) }
        XCTAssertEqual(AppIconOption(iconName: "AppIconRetired"), .standard)
    }
}
