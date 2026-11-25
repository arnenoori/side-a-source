import Foundation

#if canImport(Compression)
/// RFC 1952 gzip around the system's raw deflate, for response bodies and event frames that a phone asked to have
/// compressed (`Accept-Encoding: gzip`, capability `gzip`). Apple platforms only; a build without Compression sends plain.
public enum Gzip {
    /// Below this a body costs about as much compressed as plain.
    public static let threshold = 1_024

    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }

    public static func compress(_ data: Data) -> Data? {
        guard let raw = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var out = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF])
        out.append(raw)
        for value in [crc32(data), UInt32(truncatingIfNeeded: data.count)] { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        return out
    }

    /// The bytes inside `data`, nil when it is not gzip, is cut short, fails its checksum or would pass `limit`.
    public static func decompress(_ data: Data, limit: Int = 64 << 20) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var index = 10
        if flags & 4 != 0 {
            guard index + 2 <= bytes.count else { return nil }
            index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8
        }
        for bit: UInt8 in [8, 16] where flags & bit != 0 {
            guard let end = bytes[min(index, bytes.count)...].firstIndex(of: 0) else { return nil }
            index = end + 1
        }
        if flags & 2 != 0 { index += 2 }
        guard index < bytes.count - 8 else { return nil }
        let tail = bytes.suffix(8)
        let sum = tail.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        let size = tail.suffix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        guard Int(size) <= limit, let plain = try? (Data(bytes[index..<(bytes.count - 8)]) as NSData).decompressed(using: .zlib) as Data,
              plain.count == Int(size), crc32(plain) == sum else { return nil }
        return plain
    }
}
#endif
