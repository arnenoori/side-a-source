import Foundation
import SideAProtocol
@testable import SideARemoteKit
import Testing

/// What the phone makes of the Mac's frames: lenient, and every violation is `.invalid`.
@Test func clientFramesReadTheMacsFramesLeniently() {
    var frames = ClientFrames()
    let mac = { (opcode: WebSocketFrames.Opcode, payload: Data) in WebSocketFrames.frame(opcode, payload, from: .server) }
    let bytes = mac(.text, Data([0x68, 0xC3])) + mac(.binary, Data([1, 2])) + mac(.ping, Data("p".utf8))
        + mac(.close, Data([0x03])) + mac(.close, WebSocketFrames.closePayload(4401, "gone", maxReason: 123)) + mac(.close, Data())
    #expect(frames.feed(bytes) == [.message(.text("h\u{FFFD}")), .message(.data(Data([1, 2]))), .ping(Data("p".utf8)),
                                   .close(code: 1005, reason: nil), .close(code: 4401, reason: "gone"), .close(code: 1005, reason: nil)])
    #expect(frames.feed(WebSocketFrames.frame(.text, Data(), from: .client) + mac(.text, Data())) == [.invalid])
    #expect(ClientFrames.closePayload(1000, String(repeating: "a", count: 200)).count == 122)
}
