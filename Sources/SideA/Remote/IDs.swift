import CryptoKit
import Foundation

/// Ids that reach the bridge, for the routes and the Mac's own commands alike, and ids made from text.
enum IDs {
    /// Ids go to the bridge as arguments, so nothing that could read as an option gets through.
    static func safe(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, CharacterSet.alphanumerics.contains(first), id.count <= 128 else { return false }
        return id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }
    }

    /// The first 8 bytes of the text's SHA-256, as 16 hex digits: an id that doesn't show what it was made from.
    static func hashed(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
