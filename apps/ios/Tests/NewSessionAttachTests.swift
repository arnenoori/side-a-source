import SideAProtocol
import UIKit
import XCTest
@testable import SideARemote

@MainActor
final class NewSessionAttachTests: XCTestCase {
    private let draft = "new-session-test"

    private func png() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
    }

    private func settled(_ attachments: ComposerAttachments, _ key: String, count: Int) async throws {
        for _ in 0..<100 {
            let items = attachments.items(key)
            if items.count == count, !attachments.isUploading(key) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("the tray never settled")
    }

    func testTheSheetsMenuHasOnlyWaysToAttach() {
        let rows = DrawerRows.make(canUpload: true, room: 4, hasCamera: true, clipboardHasImage: true)
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.attaches)
        XCTAssertEqual(DrawerRows.make(canUpload: false, room: 4, hasCamera: true, clipboardHasImage: true).count, 0)
    }

    func testANewSessionStartsOnTheComputerTheListShowsThenTheLastOneUsedAndNeverOneThatCantHost() {
        let hosts = ["studio", "laptop"]
        XCTAssertEqual(NewSessionSheet.target(picked: nil, shown: "laptop", last: "studio", hosts: hosts), "laptop")
        XCTAssertEqual(NewSessionSheet.target(picked: nil, shown: nil, last: "laptop", hosts: hosts), "laptop")
        XCTAssertEqual(NewSessionSheet.target(picked: nil, shown: nil, last: nil, hosts: hosts), "studio")
        XCTAssertEqual(NewSessionSheet.target(picked: "studio", shown: "laptop", last: "laptop", hosts: hosts), "studio")
        XCTAssertEqual(NewSessionSheet.target(picked: nil, shown: "asleep", last: "gone", hosts: hosts), "studio")
        XCTAssertNil(NewSessionSheet.target(picked: nil, shown: "asleep", last: nil, hosts: []))
    }

    func testStartWaitsForAPhotoOnItsWayAndNeverLeavesAFailedOneOut() async throws {
        let attachments = ComposerAttachments()
        XCTAssertEqual(attachments.gate(draft), .ready([]))

        attachments.add(png(), to: draft)
        try await settled(attachments, draft, count: 1)
        guard case .ready(let ids) = attachments.gate(draft) else { return XCTFail("a prepared photo is ready") }
        XCTAssertEqual(ids.count, 1)

        let id = try XCTUnwrap(attachments.reserve(preview: UIImage(), in: draft))
        XCTAssertEqual(attachments.gate(draft), .uploading, "a photo still being fetched holds the start")
        attachments.fail(id, "The photo couldn't be loaded.", in: draft)
        XCTAssertEqual(attachments.gate(draft), .failed, "a failed tile holds the start until Retry or Remove")
        attachments.remove(id, from: draft)
        XCTAssertEqual(attachments.gate(draft), .ready(ids))
    }

    func testTheStartRequestNamesThePhotosAndTheSignatureCoversThem() throws {
        let plain = StartHosted(cwd: "/tmp/app", agent: .claude, prompt: "Look at this")
        let with = StartHosted(cwd: "/tmp/app", agent: .claude, prompt: "Look at this", attachments: ["0123456789ab", "ba9876543210"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(with)) as? [String: Any])
        XCTAssertEqual(json["attachments"] as? [String], ["0123456789ab", "ba9876543210"])
        XCTAssertEqual(json["prompt"] as? String, "Look at this")
        XCTAssertNotEqual(try ConfirmMessage.subject(start: plain), try ConfirmMessage.subject(start: with))
        XCTAssertEqual(try ConfirmMessage.subject(start: with), try ConfirmMessage.subject(start: with))
        let bare = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        XCTAssertEqual(bare["attachments"] as? [String], [])
    }

    func testAFailedStartLeavesThePhotosInTheTrayAndASuccessfulOneHandsThemToTheBubble() async throws {
        let attachments = ComposerAttachments()
        attachments.add(png(), to: draft)
        attachments.add(png(), to: draft)
        try await settled(attachments, draft, count: 2)
        let before = attachments.ready(draft)
        XCTAssertEqual(attachments.ready(draft), before)
        XCTAssertEqual(attachments.items(draft).count, 2)
        XCTAssertEqual(attachments.take(draft, for: "turn-1"), before)
        XCTAssertTrue(attachments.items(draft).isEmpty)
        XCTAssertEqual(attachments.sent["turn-1"]?.count, 2)
    }

    private actor Hold {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var released = false
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func release() {
            released = true
            for continuation in waiting { continuation.resume() }
            waiting = []
        }
    }

    private func held(_ attachments: ComposerAttachments, _ hold: Hold) {
        attachments.preparer = { data in
            await hold.wait()
            return ComposerAttachments.prepare(data)
        }
    }

    func testAPhotoStillBeingPreparedHoldsTheStartAndTheReply() async throws {
        let attachments = ComposerAttachments()
        let hold = Hold()
        held(attachments, hold)
        attachments.add(png(), to: draft)
        XCTAssertEqual(attachments.items(draft).count, 1)
        XCTAssertTrue(attachments.isUploading(draft))
        XCTAssertEqual(attachments.gate(draft), .uploading, "Start waits for a photo that is still being prepared")
        XCTAssertEqual(attachments.room(draft), ComposerAttachments.limit - 1)
        await hold.release()
        try await settled(attachments, draft, count: 1)
        guard case .ready(let ids) = attachments.gate(draft) else { return XCTFail("ready once prepared") }
        XCTAssertEqual(ids.count, 1)
    }

    func testDiscardingWhilePreparingLeavesNothingToInsertLater() async throws {
        let attachments = ComposerAttachments()
        let hold = Hold()
        held(attachments, hold)
        attachments.add(png(), to: draft)
        attachments.discard(draft)
        await hold.release()
        // swiftlint:disable:next sleep_literal_in_tests -- proving a photo finished after the sheet was discarded does not come back
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(attachments.items(draft).isEmpty, "a photo finished after the sheet was discarded doesn't come back")
        XCTAssertEqual(attachments.gate(draft), .ready([]))
    }

    func testSomethingThatIsNotAnImageLeavesTheTrayAsItWas() async throws {
        let attachments = ComposerAttachments()
        attachments.add(Data("not a picture".utf8), to: draft)
        XCTAssertTrue(attachments.isUploading(draft))
        for _ in 0..<100 where !attachments.items(draft).isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(attachments.items(draft).isEmpty)
        XCTAssertEqual(attachments.gate(draft), .ready([]))
    }

    func testDiscardingTheSheetEmptiesItsTray() async throws {
        let attachments = ComposerAttachments()
        attachments.add(png(), to: draft)
        try await settled(attachments, draft, count: 1)
        attachments.discard(draft)
        XCTAssertTrue(attachments.items(draft).isEmpty)
    }

    func testAMacThatLostThePhotosTakesThemAgain() async throws {
        let attachments = ComposerAttachments()
        attachments.add(png(), to: draft)
        try await settled(attachments, draft, count: 1)
        attachments.reupload(draft)
        XCTAssertTrue(attachments.isUploading(draft))
        try await settled(attachments, draft, count: 1)
        guard case .ready = attachments.gate(draft) else { return XCTFail("uploaded again") }
    }

    func testPickingAnotherMacSendsThePhotosToIt() async throws {
        let first = ComposerAttachments(), second = ComposerAttachments()
        first.add(png(), to: draft)
        first.add(png(), to: draft)
        try await settled(first, draft, count: 2)
        first.rehome(draft, to: second)
        XCTAssertTrue(first.items(draft).isEmpty)
        try await settled(second, draft, count: 2)
        XCTAssertEqual(second.items(draft).count, 2)
        second.rehome(draft, to: second)
        XCTAssertEqual(second.items(draft).count, 2)
    }

    func testAPhotoStillBeingPreparedFollowsToTheOtherMac() async throws {
        let first = ComposerAttachments(), second = ComposerAttachments()
        let hold = Hold()
        held(first, hold)
        first.add(png(), to: draft)
        XCTAssertTrue(first.isUploading(draft))
        first.rehome(draft, to: second)
        XCTAssertTrue(first.items(draft).isEmpty)
        XCTAssertEqual(second.items(draft).count, 1, "its tile moves at once")
        XCTAssertEqual(second.gate(draft), .uploading, "and Start waits for it there")
        await hold.release()
        try await settled(second, draft, count: 1)
        guard case .ready(let ids) = second.gate(draft) else { return XCTFail("ready once prepared") }
        XCTAssertEqual(ids.count, 1)
        XCTAssertTrue(first.items(draft).isEmpty, "nothing comes back to the tray it left")
    }

    func testAPhotoTheDrawerIsStillFetchingFollowsToTheOtherMac() async throws {
        let first = ComposerAttachments(), second = ComposerAttachments()
        let id = try XCTUnwrap(first.reserve(preview: UIImage(), in: draft, refetch: { nil }))
        first.rehome(draft, to: second)
        XCTAssertEqual(second.items(draft).map(\.id), [id])
        first.supply(id, png(), in: draft)
        try await settled(second, draft, count: 1)
        guard case .ready = second.gate(draft) else { return XCTFail("ready once supplied") }
        XCTAssertTrue(first.items(draft).isEmpty)
    }

    func testAFetchThatFailsAfterTheMoveFailsTheTileThere() async throws {
        let first = ComposerAttachments(), second = ComposerAttachments()
        let id = try XCTUnwrap(first.reserve(preview: UIImage(), in: draft, refetch: { nil }))
        first.rehome(draft, to: second)
        first.supply(id, nil, in: draft)
        XCTAssertEqual(second.gate(draft), .failed)
    }

    func testSomethingThatIsNotAnImageLeavesTheOtherMacsTrayToo() async throws {
        let first = ComposerAttachments(), second = ComposerAttachments()
        let hold = Hold()
        held(first, hold)
        first.add(Data("not a picture".utf8), to: draft)
        first.rehome(draft, to: second)
        await hold.release()
        for _ in 0..<100 where !second.items(draft).isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(second.items(draft).isEmpty)
        XCTAssertEqual(second.gate(draft), .ready([]))
    }

    func testOnlyAsManyPhotosFollowAsTheOtherTrayHasRoomFor() async throws {
        let first = ComposerAttachments(), crowded = ComposerAttachments()
        let hold = Hold()
        held(first, hold)
        for _ in 0..<3 { first.add(png(), to: draft) }
        for _ in 0..<(ComposerAttachments.limit - 1) { crowded.add(png(), to: draft) }
        try await settled(crowded, draft, count: ComposerAttachments.limit - 1)
        first.rehome(draft, to: crowded)
        XCTAssertEqual(crowded.items(draft).count, ComposerAttachments.limit)
        await hold.release()
        try await settled(crowded, draft, count: ComposerAttachments.limit)
        XCTAssertTrue(first.items(draft).isEmpty)
    }

    @MainActor private final class FakeUploads {
        let name: String
        var sent = 0
        var gate: Hold?
        init(_ name: String) { self.name = name }
        func attach(to tray: ComposerAttachments) {
            tray.uploader = { [self] _ in
                sent += 1
                await gate?.wait()
                return "\(name)-\(sent)"
            }
        }
    }

    private func ready(_ tray: ComposerAttachments) -> [String] {
        if case .ready(let ids) = tray.gate(draft) { return ids }
        return []
    }

    func testOnlyTheMacThePhotoMovedToUploadsIt() async throws {
        let first = ComposerAttachments(), second = ComposerAttachments()
        let a = FakeUploads("a"), b = FakeUploads("b")
        a.attach(to: first); b.attach(to: second)
        let hold = Hold()
        held(first, hold)
        first.add(png(), to: draft)
        first.rehome(draft, to: second)
        await hold.release()
        try await settled(second, draft, count: 1)
        XCTAssertEqual(a.sent, 0)
        XCTAssertEqual(b.sent, 1)
        XCTAssertEqual(ready(second), ["b-1"])
    }

    func testAPhotoMovedThereAndBackUploadsOnceToTheFirstMac() async throws {
        let first = ComposerAttachments(), second = ComposerAttachments()
        let a = FakeUploads("a"), b = FakeUploads("b")
        a.attach(to: first); b.attach(to: second)
        let hold = Hold()
        held(first, hold)
        first.add(png(), to: draft)
        first.rehome(draft, to: second)
        second.rehome(draft, to: first)
        await hold.release()
        try await settled(first, draft, count: 1)
        XCTAssertEqual(a.sent, 1)
        XCTAssertEqual(b.sent, 0)
        XCTAssertTrue(second.items(draft).isEmpty)
    }

    func testAPhotoDiscardedAfterTheMoveUploadsNowhere() async throws {
        let first = ComposerAttachments(), second = ComposerAttachments()
        let a = FakeUploads("a"), b = FakeUploads("b")
        a.attach(to: first); b.attach(to: second)
        let hold = Hold()
        held(first, hold)
        first.add(png(), to: draft)
        first.rehome(draft, to: second)
        let id = try XCTUnwrap(second.items(draft).first?.id)
        second.remove(id, from: draft)
        await hold.release()
        // swiftlint:disable:next sleep_literal_in_tests -- proving nothing is sent for a photo removed before its turn
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(a.sent + b.sent, 0)
        XCTAssertTrue(first.items(draft).isEmpty)
        XCTAssertTrue(second.items(draft).isEmpty)
    }

    func testAPhotoMidUploadGoesToTheOtherMacOnly() async throws {
        let first = ComposerAttachments(), second = ComposerAttachments()
        let a = FakeUploads("a"), b = FakeUploads("b")
        let slow = Hold()
        a.gate = slow
        a.attach(to: first); b.attach(to: second)
        first.add(png(), to: draft)
        for _ in 0..<1000 where a.sent == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(a.sent, 1, "on its way to the first Mac")
        first.rehome(draft, to: second)
        try await settled(second, draft, count: 1)
        XCTAssertEqual(ready(second), ["b-1"])
        await slow.release()
        // swiftlint:disable:next sleep_literal_in_tests -- proving the first Mac's late answer changes nothing
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(ready(second), ["b-1"], "the first Mac's answer doesn't reach the tile")
        XCTAssertEqual(b.sent, 1)
        XCTAssertTrue(first.items(draft).isEmpty)
    }
}
