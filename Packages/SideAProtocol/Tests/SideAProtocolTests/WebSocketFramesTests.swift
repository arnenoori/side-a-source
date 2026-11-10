import Foundation
import SideAProtocol
import Testing

typealias Frames = WebSocketFrames

/// Any frame, legal or not; `mask` nil sends it unmasked.
private func raw(_ opcode: UInt8, _ payload: Data, fin: Bool = true, mask: [UInt8]? = nil, rsv: UInt8 = 0) -> Data {
    var out = Data([(fin ? 0x80 : 0) | rsv | opcode])
    let bit: UInt8 = mask == nil ? 0 : 0x80
    if payload.count < 126 { out.append(bit | UInt8(payload.count)) } else if payload.count < 65536 {
        out.append(contentsOf: [bit | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
    } else {
        out.append(bit | 127)
        out.append(contentsOf: (0..<8).reversed().map { UInt8(UInt64(payload.count) >> UInt64($0 * 8) & 0xFF) })
    }
    guard let mask else { return out + payload }
    return out + mask + payload.enumerated().map { $0.element ^ mask[$0.offset & 3] }
}

/// What a decoder for `role` sends back for a peer's frame.
private func peer(_ role: Frames.Role) -> Frames.Role { role == .server ? .client : .server }
private func peerMask(_ role: Frames.Role) -> [UInt8]? { role == .server ? [0x37, 0xFA, 0x21, 0x3D] : nil }

private func drain(_ frames: inout Frames) -> [Result<Frames.Opcode, Frames.Violation>] {
    var out: [Result<Frames.Opcode, Frames.Violation>] = []
    while let next = frames.next() { out.append(next.map(\.opcode)) }
    return out
}

private func decodeAll(_ frames: inout Frames, _ bytes: Data) -> [(Frames.Opcode, Data)]? {
    frames.append(bytes)
    var out: [(Frames.Opcode, Data)] = []
    while let next = frames.next() {
        guard case .success(let frame) = next else { return nil }
        out.append(frame)
    }
    return out
}

private func violation(_ role: Frames.Role, strict: Bool, max: Int = 1 << 20, _ bytes: Data) -> Frames.Violation? {
    var frames = Frames(role: role, maxMessage: max, strict: strict)
    frames.append(bytes)
    if case .failure(let violation)? = frames.next() { return violation }
    return nil
}

@Test(arguments: [Frames.Role.server, .client], [0, 1, 125, 126, 127, 65535, 65536, 70_000])
func roundTripsAcrossLengthBoundaries(role: Frames.Role, count: Int) throws {
    let payload = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let bytes = Frames.frame(.binary, payload, from: peer(role))
    let lengthByte = bytes[1] & 0x7F
    #expect(lengthByte == (count < 126 ? UInt8(count) : count < 65536 ? 126 : 127))
    #expect(bytes[1] & 0x80 == (role == .server ? 0x80 : 0))
    #expect(bytes.count == 2 + (count < 126 ? 0 : count < 65536 ? 2 : 8) + (role == .server ? 4 : 0) + count)
    var frames = Frames(role: role, maxMessage: 1 << 20, strict: true)
    let out = try #require(decodeAll(&frames, bytes))
    #expect(out.count == 1 && out[0].0 == .binary && out[0].1 == payload)
}

@Test(arguments: [Frames.Role.server, .client])
func refusesTheWrongMasking(role: Frames.Role) {
    let wrong: [UInt8]? = role == .server ? nil : [1, 2, 3, 4]
    for strict in [true, false] {
        #expect(violation(role, strict: strict, raw(1, Data("hi".utf8), mask: wrong)) == .masking)
        // Decided from the first two bytes.
        #expect(violation(role, strict: strict, raw(1, Data("hi".utf8), mask: wrong).prefix(2)) == .masking)
    }
}

@Test(arguments: [Frames.Role.server, .client], [true, false])
func joinsFragmentsAroundControlFramesFedOneByteAtATime(role: Frames.Role, strict: Bool) {
    let mask = peerMask(role)
    let bytes = raw(1, Data("hel".utf8), fin: false, mask: mask) + raw(9, Data("p".utf8), mask: mask)
        + raw(0, Data("l".utf8), fin: false, mask: mask) + raw(10, Data(), mask: mask) + raw(0, Data("o".utf8), mask: mask)
        + raw(2, Data(repeating: 7, count: 300), mask: mask) + raw(8, Data([0x03, 0xE8]) + Data("bye".utf8), mask: mask)
    var frames = Frames(role: role, maxMessage: 1 << 20, strict: strict)
    var out: [(Frames.Opcode, Data)] = []
    for byte in bytes {
        out += decodeAll(&frames, Data([byte])) ?? []
    }
    #expect(out.map(\.0) == [.ping, .pong, .text, .binary, .close])
    #expect(out.map(\.1) == [Data("p".utf8), Data(), Data("hello".utf8), Data(repeating: 7, count: 300), Data([0x03, 0xE8]) + Data("bye".utf8)])
}

@Test func decodesManyFramesFromOneChunkAndKeepsTheTail() throws {
    let one = Frames.frame(.text, Data("x".utf8), from: .client)
    let chunk = (0..<1000).reduce(Data()) { data, _ in data + one } + one.prefix(3)
    var frames = Frames(role: .server, maxMessage: 1 << 20, strict: true)
    #expect(try #require(decodeAll(&frames, chunk)).count == 1000)
    #expect(try #require(decodeAll(&frames, one.dropFirst(3))).map(\.1) == [Data("x".utf8)])
}

@Test(arguments: [Frames.Role.server, .client], [true, false])
func refusesOrphanAndInterleavedFragments(role: Frames.Role, strict: Bool) {
    let mask = peerMask(role)
    #expect(violation(role, strict: strict, raw(0, Data("x".utf8), mask: mask)) == .orphanContinuation)
    var frames = Frames(role: role, maxMessage: 1 << 20, strict: strict)
    frames.append(raw(1, Data("a".utf8), fin: false, mask: mask) + raw(2, Data("b".utf8), mask: mask) + raw(1, Data("c".utf8), mask: mask))
    // A violation drops what was buffered behind it.
    #expect(drain(&frames) == [.failure(.interleaved)])
}

@Test func oversizeIsRefusedFromTheHeader() {
    let header = Data([0x82, 0x80 | 127, 0, 0, 0, 0, 0, 0x10, 0, 1])
    for strict in [true, false] { #expect(violation(.server, strict: strict, header) == .tooLarge) }
    #expect(violation(.client, strict: false, Data([0x82, 127, 0, 0, 0, 0, 0, 0x10, 0, 1])) == .tooLarge)
    #expect(violation(.client, strict: false, Data([0x82, 127, 0x80, 0, 0, 0, 0, 0, 0, 1])) == .malformedLength)
    let mask: [UInt8] = [1, 2, 3, 4]
    let atLimit = raw(2, Data(count: 100), mask: mask)
    #expect(violation(.server, strict: true, max: 100, atLimit) == nil)
    #expect(violation(.server, strict: true, max: 99, atLimit.prefix(2)) == .tooLarge)
}

@Test func strictCountsTheJoinedMessageFromTheHeaderLenientAfterThePayload() {
    let start = raw(1, Data(count: 60), fin: false)
    let more = raw(0, Data(count: 60))
    var strict = Frames(role: .client, maxMessage: 100, strict: true)
    strict.append(start + more.prefix(2))
    #expect(drain(&strict) == [.failure(.tooLarge)])
    var lenient = Frames(role: .client, maxMessage: 100, strict: false)
    lenient.append(start + more.prefix(2))
    #expect(drain(&lenient).isEmpty)
    lenient.append(more.dropFirst(2))
    #expect(drain(&lenient) == [.failure(.tooLarge)])
}

@Test func onlyStrictChecksReservedBitsOpcodesAndControlFrames() {
    let rsv = raw(1, Data("a".utf8), rsv: 0x40)
    #expect(violation(.client, strict: true, rsv) == .reservedBits)
    #expect(violation(.client, strict: false, rsv) == nil)

    let unknown = raw(3, Data("abc".utf8))
    #expect(violation(.client, strict: true, unknown.prefix(2)) == .unknownOpcode)
    #expect(violation(.client, strict: false, unknown.prefix(4)) == nil)
    #expect(violation(.client, strict: false, unknown) == .unknownOpcode)

    let splitPing = raw(9, Data(count: 2), fin: false)
    let longPing = raw(9, Data(count: 126))
    #expect(violation(.client, strict: true, splitPing) == .splitControl)
    #expect(violation(.client, strict: true, longPing) == .splitControl)
    var lenient = Frames(role: .client, maxMessage: 1 << 20, strict: false)
    lenient.append(splitPing + longPing)
    #expect(drain(&lenient) == [.success(.ping), .success(.ping)])
}

@Test func encodesCloseAndAcceptsTheRFCKey() {
    #expect(Frames.acceptKey("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    #expect(Frames.closePayload(4401, "", maxReason: 123) == Data([0x11, 0x31]))
    #expect(Frames.closePayload(1000, String(repeating: "é", count: 100), maxReason: 120).count == 122)
    #expect(Frames.frame(.close, Frames.closePayload(1000, "", maxReason: 123), from: .server) == Data([0x88, 2, 0x03, 0xE8]))
    // Client masks differ frame to frame.
    let masks = Set((0..<8).map { _ in Frames.frame(.ping, Data(), from: .client).suffix(4) })
    #expect(masks.count > 1)
}
