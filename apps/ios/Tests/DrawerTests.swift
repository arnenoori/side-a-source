import Photos
import SwiftUI
import UIKit
import XCTest
@testable import SideARemote

@MainActor
final class DrawerLogicTests: XCTestCase {
    // MARK: Paste

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

    // MARK: Permission

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

    // MARK: Rows

    func testTheMenuOffersWhatCanBeAttachedAndAlwaysTheOptions() {
        let all = DrawerRows.make(canUpload: true, room: 4, hasCamera: true, clipboardHasImage: true)
        XCTAssertEqual(all, DrawerRows(camera: true, photos: true, files: true, paste: true))
        XCTAssertEqual(all.count, 5)
        let none = DrawerRows.make(canUpload: false, room: 4, hasCamera: true, clipboardHasImage: true)
        XCTAssertFalse(none.attaches)
        XCTAssertEqual(none.count, 1)
        XCTAssertFalse(DrawerRows.make(canUpload: true, room: 0, hasCamera: true, clipboardHasImage: false).attaches)
        XCTAssertFalse(DrawerRows.make(canUpload: true, room: 2, hasCamera: false, clipboardHasImage: false).camera)
    }

    // MARK: Geometry

    private func layout(window: CGSize = CGSize(width: 402, height: 874), plusY: CGFloat = 800, composerWidth: CGFloat = 370,
                        menuHeight: CGFloat = 270, keyboardTop: CGFloat? = nil) -> DrawerLayout {
        DrawerLayout(window: window, safe: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0),
                     plus: CGRect(x: 16, y: plusY - 24, width: 48, height: 48),
                     composer: CGRect(x: 16, y: plusY - 24, width: composerWidth, height: 48),
                     menuSize: CGSize(width: 316, height: menuHeight), keyboardTop: keyboardTop)
    }

    func testTheMenuStaysInsideTheWindowWhetherTheKeyboardIsUpOrDown() {
        for plusY in [800.0, 560.0, 90.0] {
            let menu = layout(plusY: plusY).menu
            XCTAssertGreaterThanOrEqual(menu.minY, 62 + DrawerLayout.gutter - 0.01)
            XCTAssertLessThanOrEqual(menu.maxY, 874 - DrawerLayout.gutter + 0.01)
        }
    }

    func testTheMenuOpensAroundThePlusWhenThereIsRoom() {
        let menu = layout(plusY: 520).menu
        XCTAssertEqual(menu.midY, 520 + 7, accuracy: 0.5)
        XCTAssertEqual(menu.minX, 16)
    }

    func testThePanelStartsAsThePlusAndEndsAsTheSheet() {
        let l = layout()
        let start = PanelFrame.at(open: 0, morph: 0, layout: l, sheetTop: l.mediumTop)
        XCTAssertEqual(start.rect, l.plus)
        XCTAssertEqual(start.radius, 24)
        let menu = PanelFrame.at(open: 1, morph: 0, layout: l, sheetTop: l.mediumTop)
        XCTAssertEqual(menu.rect, l.menu)
        let sheet = PanelFrame.at(open: 1, morph: 1, layout: l, sheetTop: l.mediumTop)
        XCTAssertEqual(sheet.rect, l.sheet(top: l.mediumTop))
        XCTAssertEqual(sheet.radius, DrawerLayout.sheetRadius)
    }

    func testTheDetentsAreOrderedAndTheSheetKeepsItsGutterAtTheBottom() {
        let l = layout()
        XCTAssertLessThan(l.largeTop, l.mediumTop)
        XCTAssertLessThan(l.mediumTop, l.dismissTop)
        XCTAssertEqual(l.sheet(top: l.mediumTop).maxY, 874 - DrawerLayout.gutter)
    }

    func testTheDrawerStopsAboveTheKeyboard() {
        let l = layout(plusY: 520, keyboardTop: 560)
        XCTAssertEqual(l.sheetBottom, 560 - DrawerLayout.gutter)
        XCTAssertLessThanOrEqual(l.menu.maxY, 560 - DrawerLayout.gutter)
        XCTAssertLessThanOrEqual(l.sheet(top: l.mediumTop).maxY, 560)
        XCTAssertGreaterThanOrEqual(l.mediumTop, l.largeTop)
    }

    func testASmallPhoneWithTheKeyboardUpKeepsAUsableSheet() {
        let l = layout(window: CGSize(width: 375, height: 667), plusY: 330, keyboardTop: 407)
        XCTAssertGreaterThanOrEqual(l.sheetBottom - l.mediumTop, 250)
        XCTAssertGreaterThanOrEqual(l.mediumTop, l.largeTop)
        XCTAssertLessThanOrEqual(l.menu.maxY, 407)
    }

    func testASmallPhoneStillGetsATallEnoughSheet() {
        let l = layout(window: CGSize(width: 375, height: 667), plusY: 380)
        XCTAssertGreaterThanOrEqual(l.sheetBottom - l.mediumTop, DrawerLayout.minSheetHeight)
        XCTAssertGreaterThanOrEqual(l.mediumTop, l.largeTop)
    }

    func testReleasingASheetSettlesOnTheNearestDetentOrCloses() {
        let l = layout()
        XCTAssertEqual(l.settle(top: l.mediumTop + 10, velocity: 0), l.mediumTop)
        XCTAssertEqual(l.settle(top: l.largeTop + 30, velocity: 0), l.largeTop)
        XCTAssertEqual(l.settle(top: l.mediumTop - 20, velocity: -2500), l.largeTop)
        XCTAssertNil(l.settle(top: l.dismissTop + 20, velocity: 0))
        XCTAssertNil(l.settle(top: l.mediumTop + 20, velocity: 3000))
    }

    func testThePastTheTopOfTheLargeDetentResists() {
        let l = layout()
        XCTAssertEqual(l.rubberBanded(l.largeTop + 40), l.largeTop + 40)
        XCTAssertEqual(l.rubberBanded(l.largeTop - 30), l.largeTop - 10, accuracy: 0.001)
    }

    /// An iPad's sheet stays a panel by the composer; a phone's still opens under the status bar.
    func testATallWideWindowCapsTheSheetsHeight() {
        let pad = layout(window: CGSize(width: 1032, height: 1376), plusY: 1320, composerWidth: 720)
        XCTAssertEqual(pad.sheetBottom - pad.largeTop, DrawerLayout.sheetMaxHeight)
        XCTAssertLessThanOrEqual(pad.sheetBottom - pad.mediumTop, DrawerLayout.sheetMaxHeight)
        XCTAssertLessThan(pad.largeTop, pad.mediumTop)
        XCTAssertEqual(layout().largeTop, 62 + DrawerLayout.gutter)
    }

    /// Opened from an iPad form sheet, the drawer stays inside the sheet, not the window.
    func testTheDrawerStaysInsideTheSheetItIsIn() {
        var l = layout(window: CGSize(width: 1032, height: 1376), plusY: 800, composerWidth: 560)
        l.container = CGRect(x: 236, y: 420, width: 560, height: 440)
        XCTAssertEqual(l.sheetBottom, 860 - DrawerLayout.gutter)
        XCTAssertEqual(l.largeTop, 420 + DrawerLayout.gutter)
        XCTAssertGreaterThanOrEqual(l.mediumTop, l.largeTop)
        XCTAssertGreaterThanOrEqual(l.menu.minY, 420 + DrawerLayout.gutter)
        XCTAssertLessThanOrEqual(l.menu.maxY, 860 - DrawerLayout.gutter)
        l.keyboardTop = 760
        XCTAssertEqual(l.sheetBottom, 760 - DrawerLayout.gutter)
    }

    func testAWideWindowGetsMoreColumnsAndACappedSheet() {
        XCTAssertEqual(DrawerLayout.columns(for: 370), 3)
        XCTAssertEqual(DrawerLayout.columns(for: 560), 4)
        let wide = layout(window: CGSize(width: 1024, height: 1366), plusY: 1300, composerWidth: 900)
        XCTAssertEqual(wide.sheetWidth, DrawerLayout.sheetMaxWidth)
        XCTAssertLessThanOrEqual(wide.menu.maxX, 1024)
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
        // Nothing was ever fetched, so Retry only clears the tile.
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
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(attachments.items("s1").isEmpty)
    }
}

@MainActor
final class PasteHookTests: XCTestCase {
    /// Never the general pasteboard: on a simulator it syncs to the Mac's clipboard.
    private let board = UIPasteboard.withUniqueName()

    override func tearDown() {
        UIPasteboard.remove(withName: board.name)
    }

    private func picture() -> UIImage { UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in } }

    private func canPaste(_ view: UIView) -> Bool { view.canPerformAction(#selector(UIResponder.paste(_:)), withSender: nil) }

    private func bridge(room: Int) -> PasteBridge {
        let bridge = PasteBridge()
        bridge.pasteboard = board
        bridge.room = { room }
        return bridge
    }

    private struct Field: View {
        @State private var text = ""
        var body: some View { TextField("Message", text: $text, axis: .vertical) }
    }

    /// The composer's real field: a SwiftUI vertical TextField in a window, found the way the app finds it.
    private func realField() throws -> (UIWindow, UITextView) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        let host = UIHostingController(rootView: Field())
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        func find(_ view: UIView) -> UITextView? {
            if let text = view as? UITextView { return text }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return (window, try XCTUnwrap(find(host.view), "the SwiftUI field is no longer a UITextView"))
    }

    func testAViewThatIsntATextViewIsLeftAlone() {
        XCTAssertFalse(PasteSubclass.eligible(UITextField()))
        XCTAssertFalse(PasteSubclass.eligible(UIView()))
        let field = UITextField()
        let before = object_getClass(field)
        XCTAssertFalse(PasteSubclass.hook(field))
        XCTAssertTrue(object_getClass(field) == before)
    }

    func testAFailedLookupOrAnIneligibleViewHooksNothing() throws {
        let bridge = bridge(room: 3)
        // Nothing has the keyboard in a test: the lookup finds nothing and nothing is joined.
        bridge.install()
        XCTAssertFalse(bridge.isInstalled)
        let observed = UITextView()
        let token = observed.observe(\.text) { _, _ in }
        let before = object_getClass(observed)
        XCTAssertFalse(bridge.attach(observed))
        XCTAssertFalse(bridge.isInstalled)
        XCTAssertTrue(object_getClass(observed) == before)
        token.invalidate()
    }

    func testAViewKeyValueObservingHasSwappedIsLeftAlone() {
        let view = UITextView()
        let token = view.observe(\.text) { _, _ in }
        XCTAssertFalse(PasteSubclass.eligible(view))
        token.invalidate()
    }

    func testTheSubclassIsMadeOncePerClassAndRehookingChangesNothing() {
        let first = UITextView(), second = UITextView()
        XCTAssertTrue(PasteSubclass.hook(first))
        let made = PasteSubclass.createdCount
        let hookedClass = object_getClass(first)
        XCTAssertTrue(NSStringFromClass(try! XCTUnwrap(hookedClass)).hasPrefix("SideAPaste_"))
        XCTAssertTrue(PasteSubclass.hook(second))
        XCTAssertEqual(PasteSubclass.createdCount, made)
        XCTAssertTrue(object_getClass(second) == hookedClass)
        XCTAssertTrue(PasteSubclass.hook(first))
        XCTAssertEqual(PasteSubclass.createdCount, made)
        XCTAssertTrue(object_getClass(first) == hookedClass)
    }

    func testTheHookWorksOnTheRealSwiftUIField() throws {
        let (window, field) = try realField()
        defer { window.isHidden = true }
        let original = object_getClass(field)
        XCTAssertTrue(field.becomeFirstResponder())
        let bridge = bridge(room: 2)
        var received: Data?
        bridge.onImage = { received = $0 }
        bridge.install()
        XCTAssertTrue(bridge.isInstalled, "the lookup didn't find the field that has the keyboard")
        XCTAssertFalse(object_getClass(field) == original, "the runtime class didn't change")
        board.image = picture()
        XCTAssertTrue(canPaste(field))
        field.paste(nil)
        XCTAssertNotNil(received)
        // A full tray leaves Paste to the field, which can't paste a picture.
        bridge.room = { 0 }
        received = nil
        field.paste(nil)
        XCTAssertNil(received)
    }

    func testTextPasteOnTheRealFieldIsWhatItWasWithoutTheHook() throws {
        let (window, field) = try realField()
        defer { window.isHidden = true }
        let plain = UITextView()
        XCTAssertTrue(field.becomeFirstResponder())
        let bridge = bridge(room: 2)
        bridge.install()
        XCTAssertTrue(bridge.isInstalled)
        // The hook answers for its own pasteboard only when that holds a picture and nothing else.
        board.string = "hello"
        XCTAssertEqual(bridge.decision, .text)
        var received: Data?
        bridge.onImage = { received = $0 }
        field.paste(nil)
        XCTAssertNil(received)
        XCTAssertEqual(canPaste(field), canPaste(plain))
    }

    func testAHookedViewWhoseBridgeIsGoneBehavesAsBefore() throws {
        let view = UITextView()
        var bridge: PasteBridge? = self.bridge(room: 2)
        XCTAssertTrue(bridge!.attach(view))
        bridge = nil
        XCTAssertEqual(canPaste(view), canPaste(UITextView()))
    }
}

@MainActor
final class DrawerControllerTests: XCTestCase {
    private func controller() throws -> DrawerController {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let c = DrawerController()
        c.scene = scene
        c.windowSize = CGSize(width: 402, height: 874)
        c.safe = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
        c.plusFrame = CGRect(x: 16, y: 780, width: 48, height: 48)
        c.composerFrame = CGRect(x: 16, y: 780, width: 370, height: 48)
        return c
    }

    private let rows = DrawerRows(camera: false, photos: true, files: true, paste: false)

    private func hooks(paste: @escaping () -> Bool = { false }) -> DrawerHooks {
        DrawerHooks(room: { 3 }, reserve: { _, _ in nil }, supply: { _, _ in }, camera: {}, files: {}, picker: {},
                    pasteImage: paste, options: {})
    }

    func testClosingBeforeThePanelStartedToOpenClosesAtOnce() async throws {
        for reduceMotion in [false, true] {
            let c = try controller()
            c.toggle(rows: rows, hooks: hooks(), reduceMotion: reduceMotion)
            XCTAssertEqual(c.mode, .menu)
            c.dismiss()
            XCTAssertEqual(c.mode, .closed, "reduceMotion \(reduceMotion): nothing animated, so nothing would have finished it")
            XCTAssertFalse(c.closing)
            // The lead task that would have opened it was cancelled.
            await Task.yield(); await Task.yield()
            XCTAssertEqual(c.open, 0)
        }
    }

    func testARotationMidDragLeavesNoStuckDrag() throws {
        let c = try controller()
        c.toggle(rows: rows, hooks: hooks(), reduceMotion: false)
        c.moveSheet(to: 300)
        XCTAssertTrue(c.isDragging)
        c.windowSize = CGSize(width: 874, height: 402)
        XCTAssertEqual(c.mode, .closed)
        XCTAssertFalse(c.isDragging)
        c.toggle(rows: rows, hooks: hooks(), reduceMotion: false)
        XCTAssertFalse(c.isDragging, "a new opening starts without a drag")
        c.abort()
    }

    func testARotationMidConfirmDoesntLetTheNextConfirmFinishEarly() async throws {
        let c = try controller()
        c.toggle(rows: rows, hooks: hooks(), reduceMotion: false)
        try await Task.sleep(for: .milliseconds(60))
        c.dismiss()
        XCTAssertTrue(c.closing)
        c.landed(c.generation)
        XCTAssertEqual(c.landings, 1)
        c.abort()
        XCTAssertEqual(c.landings, 0)
        XCTAssertEqual(c.mode, .closed)
        c.toggle(rows: rows, hooks: hooks(), reduceMotion: false)
        try await Task.sleep(for: .milliseconds(60))
        c.dismiss()
        c.landed(c.generation)
        XCTAssertTrue(c.closing, "one landing is not both")
        c.abort()
    }

    func testAStaleCloseTimerCantCloseANewerOpening() async throws {
        let c = try controller()
        c.toggle(rows: rows, hooks: hooks(), reduceMotion: false)
        try await Task.sleep(for: .milliseconds(60))
        c.dismiss()
        c.abort()
        c.toggle(rows: rows, hooks: hooks(), reduceMotion: false)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(c.mode, .menu)
        XCTAssertFalse(c.closing)
        c.abort()
    }

    func testAPasteRowWithNothingToTakeKeepsTheDrawerAndSaysSo() async throws {
        let c = try controller()
        c.toggle(rows: rows, hooks: hooks(paste: { false }), reduceMotion: false)
        c.pasteFromClipboard()
        XCTAssertEqual(c.mode, .menu)
        XCTAssertTrue(c.pasteFailed)
        c.abort()
        let d = try controller()
        var pasted = false
        d.toggle(rows: rows, hooks: hooks(paste: { pasted = true; return true }), reduceMotion: false)
        d.pasteFromClipboard()
        XCTAssertTrue(pasted)
        XCTAssertTrue(d.closing || d.mode == .closed)
        d.abort()
    }

    func testAbortClosesAnOpenDrawerAndIsHarmlessOtherwise() throws {
        let c = try controller()
        c.abort()
        XCTAssertEqual(c.mode, .closed)
        c.toggle(rows: rows, hooks: hooks(), reduceMotion: false)
        c.abort()
        XCTAssertEqual(c.mode, .closed)
        XCTAssertFalse(c.hidesPlus)
    }
}
