import SwiftUI

/// The reply being written (section 4.3, streaming and pacing): text the Mac has sent is revealed from a
/// buffer at `max(45 chars/s, backlog / 0.4 s)`, on word boundaries, so it never lags the stream by much
/// more than 0.4 s and never jumps a paragraph at once. New words fade in over 120 ms. Finished blocks
/// are frozen, so only the last one re-parses. Reduce Motion shows each chunk as it lands, unfaded.
struct StreamingMarkdown: View {
    let text: String
    let sourceID: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Characters on screen; text already there when the view appears isn't replayed.
    @State private var shown: Int
    @State private var last: Date?
    /// Each reveal step still fading: the characters it showed, and when.
    @State private var reveals: [(start: Int, end: Int, at: Date)] = []
    @State private var now = Date.now

    static let minimumRate = 45.0
    static let maximumLag = 0.4
    static let fade = 0.12

    init(_ text: String, sourceID: String, startEmpty: Bool = false) {
        self.text = text
        self.sourceID = sourceID
        _shown = State(initialValue: startEmpty ? 0 : text.count)
    }

    private var catchingUp: Bool { !reduceMotion && shown < text.count }
    private var running: Bool { catchingUp || !reveals.isEmpty }

    var body: some View {
        let visible = String(text.prefix(reduceMotion ? text.count : shown))
        let split = Self.frozenEnd(of: visible)
        VStack(alignment: .leading, spacing: Space.s) {
            if split > 0 {
                FrozenMarkdown(text: String(visible.prefix(split)), sourceID: sourceID).equatable()
            }
            MarkdownView(String(visible.dropFirst(split)), sourceID: "\(sourceID)-tail", fading: fading(upTo: visible.count))
        }
        .background {
            if running {
                TimelineView(.animation) { context in
                    Color.clear.onChange(of: context.date, initial: true) { _, now in advance(to: now) }
                }
            }
        }
        .onChange(of: catchingUp) { _, running in if !running { last = nil } }
        // A replaced message can shrink (the Mac rewrote it); never show past its end.
        .onChange(of: text.count) { _, count in
            if shown > count { shown = count; reveals.removeAll() }
        }
    }

    /// The reveal steps still fading, oldest first; the newest ends at the end of what's shown.
    private func fading(upTo end: Int) -> [FadingWords] {
        reveals.map { reveal in
            FadingWords(count: max(0, min(reveal.end, end) - min(reveal.start, end)),
                        opacity: min(1, max(0, now.timeIntervalSince(reveal.at) / Self.fade)))
        }
    }

    private func advance(to now: Date) {
        self.now = now
        reveals.removeAll { now.timeIntervalSince($0.at) >= Self.fade }
        defer { last = now }
        guard catchingUp, let last else { return }
        let backlog = text.count - shown
        let rate = max(Self.minimumRate, Double(backlog) / Self.maximumLag)
        let target = min(text.count, shown + max(1, Int((rate * now.timeIntervalSince(last)).rounded())))
        let next = Self.wordBoundary(in: text, atOrAfter: target)
        // Only a crossed word boundary reveals, so a long reply isn't re-parsed for nothing.
        if next > shown {
            reveals.append((shown, next, now))
            shown = next
        }
    }

    /// The end of the word `offset` falls in, so a word never appears half written.
    static func wordBoundary(in text: String, atOrAfter offset: Int) -> Int {
        guard offset < text.count else { return text.count }
        var index = text.index(text.startIndex, offsetBy: offset)
        var count = offset
        while index < text.endIndex, !text[index].isWhitespace {
            index = text.index(after: index)
            count += 1
        }
        return count
    }

    /// Characters before the last blank line outside a code fence: blocks there are finished.
    static func frozenEnd(of text: String) -> Int {
        var end = 0, offset = 0, inFence = false, previousBlank = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let blank = trimmed.isEmpty
            // A blank line ends the block above it; the next block, a fence's opening line too, starts here.
            if !inFence, previousBlank, !blank { end = offset }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            previousBlank = blank && !inFence
            offset += line.count + 1
        }
        return end
    }
}

/// Finished blocks of a streaming reply, parsed once per change of their text.
private struct FrozenMarkdown: View, Equatable {
    let text: String
    let sourceID: String

    var body: some View { MarkdownView(text, sourceID: sourceID) }
}
