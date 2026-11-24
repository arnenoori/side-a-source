import Foundation
import Testing

private func rule(_ name: String) throws -> NSRegularExpression {
    let config = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../.swiftlint.yml")
    let text = try String(contentsOf: config, encoding: .utf8)
    let block = try #require(text.range(of: "  \(name):\n")).upperBound
    let line = try #require(text[block...].split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("regex:") })
    let quoted = line.drop { $0 != "'" }.dropFirst().dropLast()
    return try NSRegularExpression(pattern: String(quoted).replacingOccurrences(of: "''", with: "'"), options: [.anchorsMatchLines])
}

private func flags(_ regex: NSRegularExpression, _ line: String) -> Bool {
    regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
}

@Test func aStandaloneSleepIsFlaggedAndABoundedPollIsNot() throws {
    let sleeps = try rule("sleep_as_sync_in_tests")
    for line in ["    try await Task.sleep(for: .milliseconds(50))", "        try? await Task.sleep(nanoseconds: 1_000)", "    Thread.sleep(forTimeInterval: 0.2)",
                 "    usleep(10_000)", "    await Task.sleep(for: .milliseconds(5))"] {
        #expect(flags(sleeps, line), "\(line)")
    }
    for line in ["    for _ in 0..<200 where !done { try await Task.sleep(for: .milliseconds(10)) }",
                 "    while !what(), Date() < end { try await Task.sleep(for: .milliseconds(10)) }", "    let slept = sleepy()"] {
        #expect(!flags(sleeps, line), "\(line)")
    }
}

@Test func aWaitLoopNeedsABound() throws {
    let polls = try rule("unbounded_poll_in_tests")
    for line in ["        while !open { try await Task.sleep(for: .milliseconds(10)) }", "    while true { if done { break } }"] {
        #expect(flags(polls, line), "\(line)")
    }
    for line in ["    while !what(), Date() < deadline { await Task.yield() }", "    while !done, clock.now < end {}",
                 "    while attempts < 5, !done {}", "    while let next = iterator.next() {}", "    while index < count {}"] {
        #expect(!flags(polls, line), "\(line)")
    }
}
