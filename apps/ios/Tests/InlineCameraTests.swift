import UIKit
import XCTest
@testable import SideARemote

@MainActor
final class InlineCameraTests: XCTestCase {
    @MainActor private final class Tray {
        var room = 4
        var reserved: [UIImage] = []
        var supplied: [Data?] = []

        var hooks: DrawerHooks {
            DrawerHooks(room: { [self] in room - reserved.count }, reserve: { [self] image, _ in reserved.append(image); return UUID() },
                        supply: { [self] _, data in supplied.append(data) }, files: {}, picker: {}, pasteImage: { false })
        }
    }

    private func make(room: Int = 4) -> (AttachDrawer, FakeCapture, Tray) {
        let source = FakeCapture()
        let drawer = AttachDrawer(camera: CameraModel(source: source))
        let tray = Tray()
        tray.room = room
        drawer.toggle(rows: DrawerRows.make(canUpload: true, room: room, hasCamera: true, clipboardHasImage: false), hooks: tray.hooks, reduceMotion: false)
        return (drawer, source, tray)
    }

    private func settled(_ condition: () -> Bool) async throws {
        for _ in 0..<150 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "never settled")
    }

    func testTheTileOpensIntoAViewfinderAtTheGridsHeight() {
        let (drawer, source, _) = make()
        XCTAssertTrue(drawer.camera.isLive)
        XCTAssertGreaterThan(source.started, 0, "the preview runs once the drawer is up")
        drawer.openCamera()
        XCTAssertTrue(drawer.camera.shooting)
        XCTAssertTrue(drawer.camera.showsViewfinder)
        XCTAssertEqual(drawer.height, drawer.detents.large)
        drawer.closeCamera()
        XCTAssertFalse(drawer.camera.shooting)
        XCTAssertEqual(drawer.height, drawer.detents.base, "and back to the keyboard's height")
    }

    func testTheShutterPutsAPhotoInTheTrayAndReturnsToThePanel() async throws {
        let (drawer, _, tray) = make()
        drawer.openCamera()
        drawer.shutter()
        try await settled { !tray.supplied.isEmpty }
        XCTAssertEqual(tray.reserved.count, 1)
        let bytes = try XCTUnwrap(tray.supplied.first.flatMap { $0 })
        XCTAssertNotNil(UIImage(data: bytes), "a real picture arrived")
        try await settled { !drawer.camera.shooting }
        XCTAssertEqual(drawer.height, drawer.detents.base)
        XCTAssertTrue(drawer.isOpen, "the panel stays, ready for the next one")
        XCTAssertTrue(drawer.camera.isLive)
    }

    func testSeveralPhotosInARow() async throws {
        let (drawer, _, tray) = make()
        for count in 1...3 {
            drawer.openCamera()
            drawer.shutter()
            try await settled { tray.supplied.count == count && !drawer.camera.shooting }
        }
        XCTAssertEqual(tray.reserved.count, 3)
    }

    func testAFullTrayKeepsTheShutterFromTakingAnything() async throws {
        let (drawer, _, tray) = make(room: 0)
        drawer.openCamera()
        drawer.shutter()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(tray.reserved.isEmpty)
        XCTAssertTrue(drawer.camera.shooting)
    }

    func testACameraTakenAwayShowsAGlyphNotAFrozenFrameAndWontOpen() {
        let (drawer, source, _) = make()
        source.onInterruption?(true)
        XCTAssertTrue(drawer.camera.interrupted)
        XCTAssertFalse(drawer.camera.isLive)
        drawer.openCamera()
        XCTAssertFalse(drawer.camera.shooting)
        source.onInterruption?(false)
        XCTAssertTrue(drawer.camera.isLive, "back when the camera is")
    }

    func testFlipAndFlash() {
        let (drawer, _, _) = make()
        let camera = drawer.camera
        XCTAssertFalse(camera.front)
        XCTAssertTrue(camera.hasFlash)
        XCTAssertEqual(camera.flash, .auto)
        camera.cycleFlash()
        XCTAssertEqual(camera.flash, .on)
        camera.cycleFlash()
        camera.cycleFlash()
        XCTAssertEqual(camera.flash, .auto)
        camera.flip()
        XCTAssertTrue(camera.front)
        XCTAssertFalse(camera.hasFlash, "the flash control is hidden where the camera has none")
        camera.flip()
        XCTAssertFalse(camera.front)
    }

    func testZoomStaysWithinWhatIsSensible() {
        let (drawer, source, _) = make()
        drawer.camera.setZoom(0.2)
        XCTAssertEqual(drawer.camera.zoom, 1)
        drawer.camera.setZoom(40)
        XCTAssertEqual(drawer.camera.zoom, 6)
        XCTAssertEqual(source.zoom, 6)
    }

    func testClosingTheDrawerStopsTheCameraAndShutsTheViewfinder() {
        let (drawer, source, _) = make()
        drawer.openCamera()
        drawer.abort()
        XCTAssertFalse(drawer.camera.shooting)
        XCTAssertFalse(drawer.camera.showsViewfinder)
        XCTAssertGreaterThan(source.stopped, 0)
    }

    func testNoCameraMeansAGlyphThatDoesNothing() {
        let camera = CameraModel(source: nil)
        XCTAssertEqual(camera.access, .unavailable)
        XCTAssertFalse(camera.isLive)
        let drawer = AttachDrawer(camera: camera)
        drawer.openCamera()
        XCTAssertFalse(camera.shooting)
    }

    func testAPhotosTrayTileIsAThumbnailNotTheFullPicture() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2000)).image { UIColor.green.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000)) }
        let thumbnail = AttachDrawer.thumbnail(of: try XCTUnwrap(big.jpegData(compressionQuality: 0.5)))
        XCTAssertLessThanOrEqual(max(thumbnail.size.width, thumbnail.size.height) * thumbnail.scale, 410)
        XCTAssertEqual(AttachDrawer.thumbnail(of: Data("not a picture".utf8)).size, .zero)
    }

    func testTheFlashCyclesAutoOnOff() {
        XCTAssertEqual(CaptureFlash.auto.next, .on)
        XCTAssertEqual(CaptureFlash.on.next, .off)
        XCTAssertEqual(CaptureFlash.off.next, .auto)
    }
}
