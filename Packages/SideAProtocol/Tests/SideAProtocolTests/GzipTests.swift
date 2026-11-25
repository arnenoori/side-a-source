import Foundation
import SideAProtocol
import Testing

#if canImport(Compression)
@Test func gzipRoundTripsAndRefusesDamage() throws {
    let body = Data(String(repeating: #"{"seq":1,"text":"hello hello hello"}"#, count: 400).utf8)
    let packed = try #require(Gzip.compress(body))
    #expect(packed.count < body.count / 10)
    #expect(Gzip.decompress(packed) == body)
    var damaged = packed
    damaged[damaged.count - 9] ^= 0xFF
    #expect(Gzip.decompress(damaged) == nil)
    #expect(Gzip.decompress(Data(packed.prefix(packed.count - 3))) == nil)
    #expect(Gzip.decompress(body) == nil)
    #expect(Gzip.decompress(packed, limit: 100) == nil)
    // What the standard tool writes, with its own header bytes.
    let process = Process()
    let input = Pipe(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-c"]
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    input.fileHandleForWriting.write(body)
    try input.fileHandleForWriting.close()
    let theirs = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(Gzip.decompress(theirs) == body)
}
#endif
