import Foundation
import SideAProtocol

extension SyncEngine {
    /// An event frame's JSON: a text frame as it is, a binary one gunzipped (capability `gzip`).
    static func frameText(_ message: SocketMessage) -> String? {
        switch message {
        case .text(let text): return text
        case .data(let packed): return Gzip.decompress(packed, limit: 4 << 20).map { String(decoding: $0, as: UTF8.self) }
        }
    }
}
