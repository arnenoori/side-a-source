import Foundation
@testable import SideARemoteKit
import SideAProtocol
import Testing

private func message(_ seq: Int) -> TranscriptMessage { TranscriptMessage(seq: seq, uuid: "u\(seq)", role: .assistant, text: "m\(seq)") }

private func cursor(_ seq: Int, _ rev: Int, generation: String = "g1") -> Cursor { Cursor("\(generation).\(seq).\(rev)") }

private func page(_ seqs: ClosedRange<Int>, generation: String = "g1", reset: Bool = false, rev: Int? = nil) -> TranscriptPage {
    TranscriptPage(sessionID: "s", generation: generation, messages: seqs.map(message), replaced: [],
                   before: seqs.lowerBound > 0 ? cursor(seqs.lowerBound, 0, generation: generation) : nil,
                   after: cursor(seqs.upperBound, rev ?? seqs.upperBound, generation: generation), hasMoreAfter: false, count: seqs.upperBound + 1, reset: reset)
}

private actor Pages {
    var queue: [TranscriptPage]
    var asked: [RemoteClient.Page] = []
    var subscribed: [Cursor?] = []
    init(_ queue: [TranscriptPage]) { self.queue = queue }
    func next(_ query: RemoteClient.Page) -> TranscriptPage {
        asked.append(query)
        return queue.removeFirst()
    }
    func subscribe(_ cursor: Cursor?) { subscribed.append(cursor) }
    func add(_ more: [TranscriptPage]) { queue += more }
}

private actor Seen {
    var windows: [TranscriptWindow] = []
    func add(_ window: TranscriptWindow) { windows.append(window) }
}

private func feed(_ pages: Pages) -> TranscriptFeed {
    TranscriptFeed(sessionID: "s", reloadWait: .milliseconds(5), fetch: { await pages.next($0) }, subscribe: { _, cursor in await pages.subscribe(cursor) },
                   unsubscribe: { _ in })
}

private func seqs(_ feed: TranscriptFeed) async -> [Int] { await feed.window.messages.map(\.seq) }

@Test func aResetWhileScrolledUpKeepsEveryRowOnScreen() async throws {
    let pages = Pages([page(50...59), page(40...49)])
    let feed = feed(pages)
    try await feed.loadLatest()
    try await feed.loadEarlier()
    let seen = Seen()
    let windows = await feed.windows()
    let watching = Task { for await window in windows { await seen.add(window) } }
    let held = await feed.window.messages
    #expect(held.map(\.seq) == Array(40...59))

    await pages.add([page(60...62)])
    await feed.receive(.transcriptReset(sessionID: "s", generation: "g1"))
    let after = await feed.window
    #expect(after.messages.map(\.seq) == Array(40...62) && after.messages.prefix(held.count).elementsEqual(held))
    #expect(await pages.asked.last == .after(cursor(59, 59)), "it asked for what came after, not for the newest page again")
    #expect(await seen.windows.allSatisfy { $0.messages.count >= held.count && $0.messages.prefix(held.count).elementsEqual(held) },
            "no window shown in between lacked a row that was on screen")
    #expect(await feed.cursor == cursor(62, 62))
    watching.cancel()
}

@Test func aSavedWindowIsBroughtUpToDateFromItsCursorAlone() async throws {
    let pages = Pages([page(10...11)])
    let feed = feed(pages)
    await feed.seed(TranscriptWindow(generation: "g1", messages: (5...9).map(message), hasEarlier: true, before: cursor(5, 0), after: cursor(9, 9)))
    #expect(await seqs(feed) == Array(5...9), "shown before anything is fetched")
    try await feed.loadLatest()
    #expect(await seqs(feed) == Array(5...11))
    #expect(await pages.asked == [.after(cursor(9, 9))])
    #expect(await pages.subscribed == [cursor(11, 11)])
    let window = await feed.window
    #expect(window.after == cursor(11, 11) && window.hasEarlier)
}

@Test func aSavedWindowFromAnotherGenerationIsReplacedByTheNewestPage() async throws {
    let pages = Pages([page(0...3, generation: "g2", reset: true)])
    let feed = feed(pages)
    await feed.seed(TranscriptWindow(generation: "g1", messages: (5...9).map(message), after: cursor(9, 9)))
    try await feed.loadLatest()
    #expect(await seqs(feed) == [0, 1, 2, 3])
    #expect(await pages.asked.count == 1, "the Mac's answer to the old cursor was the new page, so nothing was fetched twice")
}
