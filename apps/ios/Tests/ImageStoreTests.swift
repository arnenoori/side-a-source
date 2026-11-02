import SideAProtocol
import SideARemoteShared
import UIKit
import XCTest
@testable import SideARemote

@MainActor
final class ImageStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("images-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func png(_ color: UIColor = .red) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3)).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        }
    }

    private let ref = ImageRef(id: "ca7592e9d8a7ceb0153286777643fd5b0158456f", mime: "image/png", bytes: 96, width: 4, height: 3, source: .pasted)

    func testCacheRefusesIdsThatAreNotHex() {
        let cache = ImageCache(folder: folder)
        XCTAssertNil(cache.file("../../shared.sqlite", thumbnail: false))
        XCTAssertNil(cache.file("", thumbnail: true))
        XCTAssertNotNil(cache.file(ref.id, thumbnail: true))
        XCTAssertNotEqual(cache.file(ref.id, thumbnail: true), cache.file(ref.id, thumbnail: false))
    }

    func testTrimDropsTheLeastRecentlyUsed() throws {
        let cache = ImageCache(folder: folder, limit: 250)
        for (index, id) in ["aa", "bb", "cc"].enumerated() {
            cache.store(Data(repeating: 1, count: 100), id, thumbnail: false)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index) * 100)],
                                                  ofItemAtPath: cache.file(id, thumbnail: false)!.path)
        }
        cache.trim()
        XCTAssertNil(cache.data("aa", thumbnail: false))
        XCTAssertNotNil(cache.data("bb", thumbnail: false))
        XCTAssertNotNil(cache.data("cc", thumbnail: false))
    }

    /// Fetched once from the Mac however many ask, then served from disk with no fetch at all.
    func testFetchesOnceThenReadsFromDisk() async {
        let calls = Counter()
        let bytes = png()
        let store = ImageStore(isDemo: false, disk: ImageCache(folder: folder))
        store.fetch = { _, thumbnail in
            await calls.add(thumbnail)
            return bytes
        }
        let ref = ref
        let first = Task { await store.image(ref, thumbnail: true) }
        let second = Task { await store.image(ref, thumbnail: true) }
        let images = [await first.value, await second.value]
        XCTAssertNotNil(images[0])
        XCTAssertNotNil(images[1])
        let thumbs = await calls.thumbs
        XCTAssertEqual(thumbs, 1)

        // A fresh store (a relaunch) finds the file on disk.
        let again = ImageStore(isDemo: false, disk: ImageCache(folder: folder))
        again.fetch = { _, _ in throw URLError(.notConnectedToInternet) }
        let image = await again.image(ref, thumbnail: true)
        XCTAssertNotNil(image)
        let data = await again.data(ref)
        XCTAssertNil(data, "the original was never fetched, and Copy mustn't hand over the thumbnail")
    }

    func testOriginalBytesForCopyAndShare() async {
        let bytes = png(.blue)
        let store = ImageStore(isDemo: false, disk: ImageCache(folder: folder))
        store.fetch = { _, thumbnail in thumbnail ? Data() : bytes }
        let data = await store.data(ref)
        XCTAssertEqual(data, bytes)
        XCTAssertEqual(ref.fileName, "ca7592e9.png")
    }

    func testAFailedFetchShowsNothing() async {
        let store = ImageStore(isDemo: false, disk: ImageCache(folder: folder))
        store.fetch = { _, _ in throw URLError(.notConnectedToInternet) }
        let image = await store.image(ref, thumbnail: false)
        XCTAssertNil(image)
    }
}

private actor Counter {
    var thumbs = 0
    var originals = 0
    func add(_ thumbnail: Bool) { if thumbnail { thumbs += 1 } else { originals += 1 } }
}
