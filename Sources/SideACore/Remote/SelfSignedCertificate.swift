import CryptoKit
import Foundation

/// The DER for Side A's own P-256 certificate. The phone pins the key, not the certificate, so it carries nothing
/// beyond what TLS needs; signing is left to the caller, whose key stays in the Keychain.
public enum SelfSignedCertificate {
    /// `publicKey` is the 65-byte uncompressed point, as `SecKeyCopyExternalRepresentation` gives it.
    public static func spki(publicKey: Data) -> Data {
        der(0x30, der(0x30, oid([1, 2, 840, 10045, 2, 1]) + oid([1, 2, 840, 10045, 3, 1, 7])) + der(0x03, Data([0]) + publicKey))
    }

    /// The pin: base64url of this is the QR code's `fp`.
    public static func spkiHash(publicKey: Data) -> Data { Data(SHA256.hash(data: spki(publicKey: publicKey))) }

    public static func tbs(publicKey: Data, serial: Data, name: String, from: Date, until: Date) -> Data {
        let subject = der(0x30, der(0x31, der(0x30, oid([2, 5, 4, 3]) + der(0x0C, Data(name.utf8)))))
        return der(0x30, der(0xA0, integer(Data([2]))) + integer(serial) + ecdsaSHA256 + subject
                   + der(0x30, time(from) + time(until)) + subject + spki(publicKey: publicKey))
    }

    /// `signature` is the DER ECDSA signature of `tbs` (X9.62, SHA-256).
    public static func certificate(tbs: Data, signature: Data) -> Data {
        der(0x30, tbs + ecdsaSHA256 + der(0x03, Data([0]) + signature))
    }

    private static var ecdsaSHA256: Data { der(0x30, oid([1, 2, 840, 10045, 4, 3, 2])) }

    static func der(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        if content.count < 128 {
            out.append(UInt8(content.count))
        } else {
            var length = content.count, bytes: [UInt8] = []
            while length > 0 { bytes.insert(UInt8(length & 0xFF), at: 0); length >>= 8 }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        return out + content
    }

    static func oid(_ arcs: [UInt]) -> Data {
        var body = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var value = arc, chunk: [UInt8] = [UInt8(value & 0x7F)]
            value >>= 7
            while value > 0 { chunk.insert(UInt8(value & 0x7F) | 0x80, at: 0); value >>= 7 }
            body.append(contentsOf: chunk)
        }
        return der(0x06, body)
    }

    /// Positive and minimal: leading zeros dropped, one added back when the top bit is set.
    static func integer(_ bytes: Data) -> Data {
        var value = Data(bytes.drop { $0 == 0 })
        if value.isEmpty || value.first! & 0x80 != 0 { value.insert(0, at: 0) }
        return der(0x02, value)
    }

    /// UTCTime through 2049, GeneralizedTime after, as RFC 5280 requires.
    static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year ?? 2000
        formatter.dateFormat = year < 2050 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return der(year < 2050 ? 0x17 : 0x18, Data(formatter.string(from: date).utf8))
    }
}
