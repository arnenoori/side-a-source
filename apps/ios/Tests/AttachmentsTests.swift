import ImageIO
import UIKit
import XCTest
@testable import SideARemote

@MainActor
final class AttachmentsTests: XCTestCase {
    private func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func testAPhotoIsDownscaledToItsLongEdgeAndSentAsJPEG() throws {
        let prepared = try XCTUnwrap(ComposerAttachments.prepare(png(width: 4000, height: 3000)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared.jpeg as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 2048)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 1536)
    }

    func testASmallPhotoKeepsItsSizeAndBytesThatArentAnImageAreSkipped() throws {
        let prepared = try XCTUnwrap(ComposerAttachments.prepare(png(width: 40, height: 30)))
        XCTAssertEqual(prepared.preview.size, CGSize(width: 40, height: 30))
        XCTAssertNil(ComposerAttachments.prepare(Data("not an image".utf8)))
    }

    func testTheDemoKeepsPhotosUntilTheReplyTakesThem() async throws {
        let attachments = ComposerAttachments()
        attachments.add(png(width: 40, height: 30), to: "s1")
        // Prepared off the main actor, then kept as ready: the demo has no Mac to upload to.
        for _ in 0..<50 {
            if case .ready = attachments.items("s1").first?.state { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(attachments.items("s1").count, 1)
        XCTAssertEqual(attachments.take("s1").count, 1)
        XCTAssertTrue(attachments.items("s1").isEmpty)
        XCTAssertEqual(attachments.room("s1"), ComposerAttachments.limit)
    }
}
