import SwiftUI
import UIKit
import XCTest
@testable import SideARemote

@MainActor
final class SelectableTextTests: XCTestCase {
    /// On the phone a two-line message's text view was proposed its height less a floating-point hair, which snapped
    /// down a whole pixel; TextKit then drew only the first line. The height SelectableText reports survives that.
    func testAMessageKeepsItsLastLineWhenItsHeightSnapsDown() throws {
        let text = "Looks right. Run the suite again and push if it's green."
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.attributedText = SelectableText.render(AttributedString(text), style: SelectableText.Style(lineSpacing: 0), size: .large)
        let needed = view.sizeThatFits(CGSize(width: 243, height: CGFloat.greatestFiniteMagnitude)).height
        let line = UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).lineHeight
        XCTAssertGreaterThan(needed, line * 1.5, "the message wraps to two lines at this width")

        // What the app saw: the reported height, a hair under, snapped down to the 3x pixel grid.
        func snapped(_ height: CGFloat) -> CGFloat { floor((height - 1e-12) * 3) / 3 }
        XCTAssertLessThan(snapped(needed), needed, "without the spare the frame comes out a pixel short")
        let height = snapped(SelectableText.withSlack(needed))
        XCTAssertGreaterThanOrEqual(height, needed)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.isHidden = false
        defer { window.isHidden = true }
        window.addSubview(view)
        view.frame = CGRect(x: 20, y: 375, width: 243, height: height)
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            UIColor.white.setFill()
            context.fill(view.bounds)
            view.layer.render(in: context.cgContext)
        }
        XCTAssertTrue(Self.hasInk(image, rows: 0.1..<0.45), "first line")
        XCTAssertTrue(Self.hasInk(image, rows: 0.6..<0.95), "second line")
    }

    /// Whether any pixel in that band of rows (fractions of the height) is dark, as text is on the white it's drawn on.
    private static func hasInk(_ image: UIImage, rows: Range<CGFloat>) -> Bool {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let perPixel = cg.bitsPerPixel / 8
        let first = Int(CGFloat(cg.height) * rows.lowerBound), last = Int(CGFloat(cg.height) * rows.upperBound)
        for y in first..<last {
            for x in 0..<cg.width {
                let i = y * cg.bytesPerRow + x * perPixel
                if Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2]) < 200 { return true }
            }
        }
        return false
    }
}
