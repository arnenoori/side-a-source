import Foundation
@testable import SideA
import Testing

/// Open Terminal exports SIDE_A_PIN, and the shell line finds the account by the file the bridge's pin_name wrote.
@Test @MainActor func aTerminalsPinNamesTheFileTheBridgeWrote() throws {
    let names = ["Work", "My Account!", "Straße", "Rene\u{301}", "Ren\u{E9}", "ﬁnance", "İstanbul", "日本", "  --a--b  ", "Ω team", "K\u{212A}"]
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", "import json, sys; sys.path.insert(0, sys.argv[1]); import sidea_bridge; print(json.dumps([sidea_bridge.pin_name(n) for n in json.load(sys.stdin)]))",
                         TranscriptFixture.bridge.deletingLastPathComponent().path]
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    input.fileHandleForWriting.write(try JSONEncoder().encode(names))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let expected = try JSONDecoder().decode([String].self, from: data)
    #expect(names.map(AccountStore.pinName) == expected)
    #expect(AccountStore.pinName("Straße") == "strasse")
}
