import Foundation
@testable import SideAProtocol
import Testing

@Test func framesKeepTheirByteLayout() throws {
    let frame = TunnelFrame(.data, 0x0001_0007, Data([1, 2, 3]))
    #expect(frame.encoded == Data([2, 0, 1, 0, 7, 1, 2, 3]))
    #expect(TunnelFrame(frame.encoded) == frame)
    #expect(TunnelFrame.credit(9, 262_144).granted == 262_144)
    #expect(TunnelFrame(Data([9, 0, 0, 0, 1])) == nil)
    #expect(TunnelFrame(Data([2, 0, 0])) == nil)
    #expect(TunnelFrame(Data([2, 0, 0, 0, 1]) + Data(count: TunnelFrame.maxPayload + 1)) == nil)
    #expect(TunnelControl(text: #"{"type":"mac","online":false}"#)?.online == false)
    #expect(TunnelControl(type: "pairing").text == #"{"type":"pairing"}"#)
    // What the relay reads to watch a Mac: its spelling is the relay's too.
    #expect(TunnelControl.watch.text == #"{"type":"watch"}"#)
    #expect(TunnelControl.goodbye(TunnelControl.Goodbye.sleep).text == #"{"reason":"sleep","type":"goodbye"}"#)
    #expect([TunnelControl.Goodbye.quit, TunnelControl.Goodbye.off] == ["quit", "off"])
}

@Test func controlTextNeverTraps() {
    let samples = [
        #"{"type":"gone","slot":-1}"#, #"{"type":"gone","slot":1e30}"#, #"{"type":"gone","slot":4294967296}"#,
        #"{"type":"gone","slot":"1"}"#, #"{"type":"devices","devices":[{"id":1}]}"#, #"{"type":null}"#, "[]", "", "{", "pong",
        #"{"type":"mac","online":"yes"}"#, #"{"type":"pairing","expiresAt":"NaN"}"#,
    ]
    var generator = SystemRandomNumberGenerator()
    let random = (0..<500).map { _ in
        String(decoding: (0..<Int.random(in: 0..<64, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }, as: UTF8.self)
    }
    for text in samples + random {
        _ = TunnelControl(text: text)
    }
    #expect(TunnelControl(text: #"{"type":"gone","slot":-1}"#)?.slot == -1)
    #expect(TunnelControl(text: #"{"type":"gone","slot":1e30}"#) == nil)
}
