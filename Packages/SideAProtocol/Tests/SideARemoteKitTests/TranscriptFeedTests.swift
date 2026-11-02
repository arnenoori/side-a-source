import Foundation
@testable import SideARemoteKit
import SideAProtocol
import Testing

private func message(_ seq: Int, _ text: String = "m") -> TranscriptMessage {
    TranscriptMessage(seq: seq, uuid: "u\(seq)", role: .assistant, text: "\(text)\(seq)")
}

private func cursor(_ generation: String, _ seq: Int, _ rev: Int) -> Cursor { Cursor("\(generation).\(seq).\(rev)") }

private func page(_ seqs: ClosedRange<Int>?, generation: String = "g1", more: Bool = false, replaced: [TranscriptMessage] = [],
                  reset: Bool = false, rev: Int? = nil) -> TranscriptPage {
    let messages = seqs.map { $0.map { message($0) } } ?? []
    let end = seqs?.upperBound ?? 0
    return TranscriptPage(sessionID: "s", generation: generation, messages: messages, replaced: replaced,
                          before: (seqs?.lowerBound ?? 0) > 0 ? cursor(generation, seqs!.lowerBound, 0) : nil,
                          after: cursor(generation, end, rev ?? end), hasMoreAfter: more, count: end + 1, reset: reset)
}

private func delta(_ messages: [TranscriptMessage], generation: String = "g1", rev: Int) -> TranscriptDelta {
    TranscriptDelta(sessionID: "s", generation: generation, messages: messages, cursor: cursor(generation, messages.last?.seq ?? 0, rev))
}

/// A feed whose pages come from `pages`, in order, recording what it asked for.
private actor Pages {
    var queue: [Result<TranscriptPage, Error>]
    var asked: [RemoteClient.Page] = []
    var subscribed: [Cursor?] = []
    init(_ queue: [Result<TranscriptPage, Error>]) { self.queue = queue }
    func next(_ query: RemoteClient.Page) throws -> TranscriptPage {
        asked.append(query)
        return try queue.removeFirst().get()
    }
    func subscribe(_ cursor: Cursor?) { subscribed.append(cursor) }
    func add(_ more: [Result<TranscriptPage, Error>]) { queue += more }
}

private func feed(_ pages: Pages) -> TranscriptFeed {
    TranscriptFeed(sessionID: "s", fetch: { try await pages.next($0) }, subscribe: { _, cursor in await pages.subscribe(cursor) }, unsubscribe: { _ in })
}

private func seqs(_ feed: TranscriptFeed) async -> [Int] { await feed.window.messages.map(\.seq) }

@Test func aDeltaAfterAGapIsRepairedFromAfterPagesWithoutDuplicates() async throws {
    let pages = Pages([.success(page(5...9))])
    let feed = feed(pages)
    try await feed.loadLatest()
    #expect(await seqs(feed) == Array(5...9))
    #expect(await pages.subscribed == [cursor("g1", 9, 9)])

    // 10 and 11 come in order and carry the cursor to follow; 15 skips 12–14.
    await feed.receive(.transcriptAppend(delta([message(10), message(11)], rev: 100)))
    #expect(await seqs(feed) == Array(5...11))
    #expect(await feed.cursor == cursor("g1", 11, 100))
    await pages.add([.success(page(10...13, more: true, replaced: [message(7, "grown")], rev: 104)), .success(page(14...15, rev: 106))])
    await feed.receive(.transcriptAppend(delta([message(15), message(16)], rev: 107)))
    #expect(await feed.window.repairing)
    // Arrives mid-repair: buffered, applied once.
    await feed.receive(.transcriptAppend(delta([message(17)], rev: 108)))
    await feed.settled()
    let window = await feed.window
    #expect(window.messages.map(\.seq) == Array(5...17) && !window.repairing)
    #expect(window.messages[2].text == "grown7")
    // The repair followed the delta's cursor, never one built from a seq.
    #expect(await pages.asked == [.latest, .after(cursor("g1", 11, 100)), .after(cursor("g1", 13, 104))])
    #expect(await feed.cursor == cursor("g1", 17, 108))
}

@Test func replaceChangesOnlyHeldMessages() async throws {
    let pages = Pages([.success(page(0...3))])
    let feed = feed(pages)
    try await feed.loadLatest()
    await feed.receive(.transcriptReplace(delta([message(2, "new"), message(9, "new")], rev: 50)))
    let window = await feed.window
    #expect(window.messages.map(\.text) == ["m0", "m1", "new2", "m3"] && !window.hasEarlier)
    #expect(await feed.cursor == cursor("g1", 9, 50))
}

@Test func resetAndAStaleCursorStartTheWindowAgain() async throws {
    let pages = Pages([.success(page(5...9)), .success(page(0...2, generation: "g2"))])
    let feed = feed(pages)
    try await feed.loadLatest()
    #expect(await feed.window.hasEarlier)
    await feed.receive(.transcriptReset(sessionID: "s", generation: "g2"))
    #expect(await feed.window.generation == "g2")
    #expect(await seqs(feed) == [0, 1, 2])

    // A delta from another generation also resets.
    await pages.add([.success(page(0...3, generation: "g3"))])
    await feed.receive(.transcriptAppend(delta([message(3)], generation: "g3", rev: 3)))
    #expect(await feed.window.generation == "g3")

    // An `after` page from a newer generation answers reset: true.
    await pages.add([.success(page(0...6, generation: "g4", reset: true)), .success(page(0...6, generation: "g4"))])
    await feed.receive(.transcriptAppend(delta([message(9)], generation: "g3", rev: 9)))
    await feed.settled()
    let window = await feed.window
    #expect(window.generation == "g4" && window.messages.count == 7 && !window.repairing)
    #expect(await pages.subscribed == [cursor("g1", 9, 9), cursor("g2", 2, 2), cursor("g3", 3, 3), cursor("g4", 6, 6)])
}

@Test func loadEarlierPrependsTheOlderPage() async throws {
    let pages = Pages([.success(page(5...9)), .success(page(0...4))])
    let feed = feed(pages)
    try await feed.loadLatest()
    try await feed.loadEarlier()
    let window = await feed.window
    #expect(window.messages.map(\.seq) == Array(0...9) && !window.hasEarlier)
    #expect(await pages.asked.last == .before(cursor("g1", 5, 0)))
}
