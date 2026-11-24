import Photos
import SwiftUI
import UIKit
import XCTest
@testable import SideARemote

@MainActor
final class DrawerLogicTests: XCTestCase {
    func testAnImageOnlyClipboardAttachesAndTextStaysText() {
        XCTAssertEqual(PasteDecision.decide(hasText: false, hasImage: true, room: 3), .image)
        XCTAssertEqual(PasteDecision.decide(hasText: true, hasImage: false, room: 3), .text)
        XCTAssertEqual(PasteDecision.decide(hasText: false, hasImage: false, room: 3), .text)
    }

    func testAMixedClipboardPastesAsText() {
        XCTAssertEqual(PasteDecision.decide(hasText: true, hasImage: true, room: 3), .text)
    }

    func testAFullTrayLeavesThePasteToTheField() {
        XCTAssertEqual(PasteDecision.decide(hasText: false, hasImage: true, room: 0), .text)
    }

    func testAnItemIsJudgedByTheTypesItIsOfferedAs() {
        XCTAssertEqual(PasteDecision.decide(types: ["public.png", "public.tiff"], room: 2), .image)
        XCTAssertEqual(PasteDecision.decide(types: ["public.utf8-plain-text", "public.png"], room: 2), .text)
        XCTAssertEqual(PasteDecision.decide(types: ["public.url", "public.jpeg"], room: 2), .text)
        XCTAssertEqual(PasteDecision.decide(types: ["not.a.type"], room: 2), .text)
    }

    func testOnlyTheStatesThatCanListRecentsListThem() {
        XCTAssertTrue(PhotoAccess.full.canListRecents)
        XCTAssertTrue(PhotoAccess.limited.canListRecents)
        XCTAssertFalse(PhotoAccess.notDetermined.canListRecents)
        XCTAssertFalse(PhotoAccess.denied.canListRecents)
    }

    func testTheSystemAlertIsAskedForOnlyOnceAndOnlyWhenOpened() {
        XCTAssertTrue(PhotoAccess.notDetermined.asksOnOpen)
        for state in [PhotoAccess.full, .limited, .denied] { XCTAssertFalse(state.asksOnOpen) }
    }

    func testLimitedLibrariesCanBeWidenedAndRefusalsPointToSettings() {
        XCTAssertTrue(PhotoAccess.limited.canWiden)
        XCTAssertFalse(PhotoAccess.full.canWiden)
        XCTAssertTrue(PhotoAccess.denied.needsSettings)
        XCTAssertFalse(PhotoAccess.notDetermined.needsSettings)
    }

    func testTheMenuOffersWhatCanBeAttachedAndAlwaysTheOptions() {
        let all = DrawerRows.make(canUpload: true, room: 4, hasCamera: true, clipboardHasImage: true)
        XCTAssertEqual(all, DrawerRows(camera: true, photos: true, files: true, paste: true))
        XCTAssertEqual(all.count, 4)
        let none = DrawerRows.make(canUpload: false, room: 4, hasCamera: true, clipboardHasImage: true)
        XCTAssertFalse(none.attaches)
        XCTAssertEqual(none.count, 0)
        XCTAssertFalse(DrawerRows.make(canUpload: true, room: 0, hasCamera: true, clipboardHasImage: false).attaches)
        XCTAssertFalse(DrawerRows.make(canUpload: true, room: 2, hasCamera: false, clipboardHasImage: false).camera)
    }
}


@MainActor
final class PanelLogicTests: XCTestCase {
    private let detents = PanelDetents(base: 336, window: 874, safeTop: 62)

    func testThePanelOpensAtTheKeyboardsHeightAndPullsUpToTheGrid() {
        XCTAssertGreaterThan(detents.large, detents.base)
        XCTAssertLessThanOrEqual(detents.large, 874 * 0.82)
        XCTAssertEqual(PanelDetents(base: 300, window: 400, safeTop: 20).large, 300)
    }

    func testReleasingSettlesOnTheNearestRestOrCloses() {
        XCTAssertEqual(detents.settle(height: 340, velocity: 0), .base)
        XCTAssertEqual(detents.settle(height: detents.large - 10, velocity: 0), .large)
        XCTAssertEqual(detents.settle(height: 340, velocity: -2000), .large, "a flick up carries on")
        XCTAssertEqual(detents.settle(height: detents.large, velocity: 3000), .base, "a flick down from the grid comes back to the keyboard's height")
        XCTAssertEqual(detents.settle(height: 336 - detents.dismissDistance - 20, velocity: 0), .dismiss)
        XCTAssertEqual(detents.settle(height: 336, velocity: 1800), .dismiss)
    }

    func testPastTheLargeDetentThePanelResists() {
        XCTAssertEqual(detents.rubberBanded(detents.large - 50), detents.large - 50)
        XCTAssertEqual(detents.rubberBanded(detents.large + 90), detents.large + 30, accuracy: 0.001)
    }

    func testTheKeyboardsHeightIsRememberedPerOrientation() {
        var heights = KeyboardHeights()
        XCTAssertEqual(heights.height(landscape: false, isPad: false), 336, "a default before any keyboard was seen")
        heights.remember(346, landscape: false)
        heights.remember(200, landscape: true)
        XCTAssertEqual(heights.height(landscape: false, isPad: false), 346)
        XCTAssertEqual(heights.height(landscape: true, isPad: false), 200)
        heights.remember(48, landscape: false)
        XCTAssertEqual(heights.height(landscape: false, isPad: false), 346, "a shortcuts bar is not a keyboard")
    }

    func testOnlyAnIPadWithoutADockedSoftKeyboardGetsAPopover() {
        XCTAssertEqual(PanelPresentation.decide(isPad: false, hardwareKeyboard: true, keyboardDocked: false), .keyboardArea)
        XCTAssertEqual(PanelPresentation.decide(isPad: true, hardwareKeyboard: false, keyboardDocked: true), .keyboardArea)
        XCTAssertEqual(PanelPresentation.decide(isPad: true, hardwareKeyboard: true, keyboardDocked: true), .popover)
        XCTAssertEqual(PanelPresentation.decide(isPad: true, hardwareKeyboard: false, keyboardDocked: false), .popover)
    }

    func testTheCameraTileDoesWhatThePermissionAllows() {
        let notYet = CameraAccess(.notDetermined, hasCamera: true)
        XCTAssertTrue(notYet.asksOnTap)
        XCTAssertFalse(notYet.showsPreview)
        let allowed = CameraAccess(.authorized, hasCamera: true)
        XCTAssertTrue(allowed.showsPreview)
        XCTAssertTrue(allowed.opensCamera)
        let refused = CameraAccess(.denied, hasCamera: true)
        XCTAssertFalse(refused.showsPreview)
        XCTAssertTrue(refused.opensCamera, "the full camera path says what to do about a refusal")
        XCTAssertEqual(CameraAccess(.restricted, hasCamera: true), .denied)
        let none = CameraAccess(.authorized, hasCamera: false)
        XCTAssertEqual(none, .unavailable)
        XCTAssertFalse(none.showsPreview)
        XCTAssertFalse(none.opensCamera)
    }

    func testThePreviewIsUprightForHowTheInterfaceIsHeld() {
        XCTAssertEqual(CameraAccess.previewAngle(for: .portrait), 90)
        XCTAssertEqual(CameraAccess.previewAngle(for: .landscapeRight), 0)
        XCTAssertEqual(CameraAccess.previewAngle(for: .landscapeLeft), 180)
        XCTAssertEqual(CameraAccess.previewAngle(for: .portraitUpsideDown), 270)
    }

    func testAWideWindowGetsMoreColumns() {
        XCTAssertEqual(DrawerGrid.columns(for: 370), 3)
        XCTAssertEqual(DrawerGrid.columns(for: 700), 5)
    }
}

@MainActor
final class DrawerAttachmentTests: XCTestCase {
    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { UIColor.red.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
    }

    func testAReservedPhotoShowsAtOnceAndHoldsTheReplyUntilItsBytesArrive() async throws {
        let attachments = ComposerAttachments()
        let id = try XCTUnwrap(attachments.reserve(preview: image(), in: "s1"))
        XCTAssertEqual(attachments.items("s1").count, 1)
        XCTAssertTrue(attachments.isUploading("s1"))
        attachments.supply(id, try XCTUnwrap(image().pngData()), in: "s1")
        for _ in 0..<100 {
            if case .ready = attachments.items("s1").first?.state { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .ready = attachments.items("s1").first?.state else { return XCTFail("never became ready") }
        XCTAssertEqual(attachments.take("s1").count, 1)
    }

    func testAPhotoThatCouldntBeLoadedFailsInsteadOfWaitingForever() {
        let attachments = ComposerAttachments()
        let id = attachments.reserve(preview: image(), in: "s1")!
        attachments.supply(id, nil, in: "s1")
        guard case .failed = attachments.items("s1").first?.state else { return XCTFail("expected a failure") }
        XCTAssertFalse(attachments.isUploading("s1"))
        attachments.retry(id, in: "s1")
        XCTAssertTrue(attachments.items("s1").isEmpty)
    }

    func testRetryOnAPhotoThatNeverLoadedFetchesItAgain() async throws {
        let attachments = ComposerAttachments()
        let bytes = try XCTUnwrap(image().pngData())
        var fetched = 0
        let id = try XCTUnwrap(attachments.reserve(preview: image(), in: "s1", refetch: { fetched += 1; return bytes }))
        attachments.supply(id, nil, in: "s1")
        guard case .failed = attachments.items("s1").first?.state else { return XCTFail("expected a failure") }
        attachments.retry(id, in: "s1")
        for _ in 0..<100 {
            if case .ready = attachments.items("s1").first?.state { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(fetched, 1)
        guard case .ready = attachments.items("s1").first?.state else { return XCTFail("never became ready") }
    }

    func testTheTrayStopsTakingReservationsAtTheLimit() {
        let attachments = ComposerAttachments()
        for _ in 0..<ComposerAttachments.limit { XCTAssertNotNil(attachments.reserve(preview: image(), in: "s1")) }
        XCTAssertNil(attachments.reserve(preview: image(), in: "s1"))
        XCTAssertEqual(attachments.room("s1"), 0)
    }

    func testRemovingAReservedPhotoBeforeItsBytesArriveLeavesNothingBehind() async throws {
        let attachments = ComposerAttachments()
        let id = attachments.reserve(preview: image(), in: "s1")!
        attachments.remove(id, from: "s1")
        attachments.supply(id, try XCTUnwrap(image().pngData()), in: "s1")
        // swiftlint:disable:next sleep_literal_in_tests -- proving a removed reservation stays gone when its bytes arrive: there is no event for "nothing happened"
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(attachments.items("s1").isEmpty)
    }
}

@MainActor
final class ComposerFieldTests: XCTestCase {
    /// Never the general pasteboard: on a simulator it syncs to the Mac's clipboard.
    private func field(board: UIPasteboard, room: Int) -> (ComposerTextView, () -> Int) {
        let view = ComposerTextView()
        view.pasteboard = board
        view.pasteRoom = { room }
        var pasted = 0
        view.onPasteImage = { _ in pasted += 1 }
        return (view, { pasted })
    }

    private func board() throws -> UIPasteboard {
        let board = try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("sidea-field-\(UUID().uuidString)"), create: true))
        board.items = []
        return board
    }

    private func picture() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { UIColor.blue.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
    }

    func testPastingAPictureAttachesItAndTextStaysText() throws {
        let clipboard = try board()
        let (view, pasted) = field(board: clipboard, room: 2)
        clipboard.image = picture()
        XCTAssertTrue(view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        view.paste(nil)
        XCTAssertEqual(pasted(), 1)

        clipboard.string = "hello"
        view.paste(nil)
        XCTAssertEqual(pasted(), 1, "text is the field's own paste")
    }

    func testAFullTrayLeavesThePasteToTheField() throws {
        let clipboard = try board()
        let (view, pasted) = field(board: clipboard, room: 0)
        clipboard.image = picture()
        view.paste(nil)
        XCTAssertEqual(pasted(), 0)
    }

    func testTintingACommandChangesOnlyItsColourAndLeavesTheCaretAndWhatIsTypedNextPlain() {
        let view = ComposerTextView()
        view.text = "/review now"
        view.selectedRange = NSRange(location: 4, length: 0)
        view.restyle([NSRange(location: 0, length: 7)], tint: .red)
        XCTAssertEqual(view.text, "/review now", "the text is the plain text that is sent")
        XCTAssertEqual(view.selectedRange, NSRange(location: 4, length: 0))
        let tinted = view.textStorage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? UIColor
        let plain = view.textStorage.attribute(.foregroundColor, at: 9, effectiveRange: nil) as? UIColor
        XCTAssertEqual(tinted, .red)
        XCTAssertEqual(plain, .label)
        XCTAssertEqual(view.typingAttributes[.foregroundColor] as? UIColor, .label)
        let tintedFont = view.textStorage.attribute(.font, at: 2, effectiveRange: nil) as? UIFont
        let plainFont = view.textStorage.attribute(.font, at: 9, effectiveRange: nil) as? UIFont
        XCTAssertEqual(tintedFont, plainFont)
        view.text = "review now"
        view.restyle([], tint: .red)
        XCTAssertEqual(view.textStorage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? UIColor, .label)
    }

    func testThePlaceholderShowsOnlyWhileTheFieldIsEmpty() {
        let view = ComposerTextView()
        view.updatePlaceholder()
        XCTAssertFalse(view.placeholderLabel.isHidden)
        view.text = "x"
        view.updatePlaceholder()
        XCTAssertTrue(view.placeholderLabel.isHidden)
    }
}

@MainActor
final class AttachDrawerTests: XCTestCase {
    private func hooks(room: Int = 4) -> DrawerHooks {
        DrawerHooks(room: { room }, reserve: { _, _ in UUID() }, supply: { _, _ in }, files: {}, picker: {},
                    pasteImage: { false })
    }

    private func open(_ drawer: AttachDrawer) {
        drawer.toggle(rows: DrawerRows.make(canUpload: true, room: 4, hasCamera: false, clipboardHasImage: false), hooks: hooks(), reduceMotion: false)
    }

    func testThePanelOpensAtTheKeyboardsHeightAndTheSamePressBringsTheKeyboardBack() {
        let drawer = AttachDrawer()
        open(drawer)
        XCTAssertTrue(drawer.isOpen)
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        XCTAssertEqual(drawer.height, KeyboardMetrics.shared.panelHeight(landscape: false, isPad: isPad))
        XCTAssertEqual(drawer.height, drawer.detents.base)
        XCTAssertFalse(drawer.isLarge)
        open(drawer)
        XCTAssertFalse(drawer.isOpen)
        XCTAssertFalse(KeyboardMetrics.shared.panelIsShowing)
    }

    func testPullingUpSettlesOnTheGridAndPullingDownFarEnoughCloses() {
        let drawer = AttachDrawer()
        open(drawer)
        drawer.drag(by: -300)
        drawer.endDrag(velocity: -800)
        XCTAssertTrue(drawer.isLarge)
        XCTAssertEqual(drawer.height, drawer.detents.large)
        drawer.toggleDetent()
        XCTAssertEqual(drawer.height, drawer.detents.base)
        drawer.drag(by: 200)
        drawer.endDrag(velocity: 600)
        XCTAssertFalse(drawer.isOpen, "a long pull down closes it like the keyboard")
    }

    func testTheKeyboardGoingAwayTakesThePanelWithIt() {
        let drawer = AttachDrawer()
        open(drawer)
        drawer.fieldEnded()
        XCTAssertFalse(drawer.isOpen)
    }

    func testTheCameraTileIsAGlyphWhereThereIsNoCamera() {
        XCTAssertFalse(AttachDrawer().camera.access.showsPreview, "no camera on a simulator, and nothing needed to know")
    }
}
