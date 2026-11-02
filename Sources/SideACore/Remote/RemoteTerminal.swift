import Foundation
import SideAProtocol

/// The pure half of `/v1/ws/term/{name}` (protocol's terminal section, hosting's Terminal streaming): numbered input,
/// who decides the window size, and the startup queries tmux sends each new client.
public enum RemoteTerminal {
    /// One viewer's input: frames in order, each once.
    public struct Input: Sendable, Equatable {
        public private(set) var applied: UInt32

        public init(applied: UInt32 = 0) { self.applied = applied }

        public enum Outcome: Sendable, Equatable {
            /// Write these bytes to the PTY, then ack.
            case write(Data)
            /// Already written; ack it again.
            case again
            /// A frame is missing: close with 4422.
            case gap
            /// Over 16 KiB: ack with `too_large`. It counts as handled, so the next frame isn't a gap.
            case tooLarge
        }

        public mutating func take(seq: UInt32, bytes: Data) -> Outcome {
            if seq <= applied { return .again }
            guard seq == applied &+ 1 else { return .gap }
            applied = seq
            return bytes.count > TermFrame.maxInput ? .tooLarge : .write(bytes)
        }
    }

    // MARK: Size

    public struct Phone: Sendable, Equatable {
        public let cols: Int
        public let rows: Int
        /// Its last input or resize.
        public let active: TimeInterval
        public init(cols: Int, rows: Int, active: TimeInterval) { self.cols = cols; self.rows = rows; self.active = active }
    }

    public enum Size: Sendable, Equatable {
        /// No phone watching: plain tmux behaviour.
        case free
        /// A Mac client typed in the last minute: it owns the window.
        case mac
        /// The phone with the latest input or resize sets it.
        case phone(cols: Int, rows: Int)

        public var owner: String { self == .mac || self == .free ? "mac" : "phone" }
    }

    /// Decision 5: the Mac wins while it's typing. `macActivity` is each Mac client's `client_activity`.
    public static func size(phones: [Phone], macActivity: [TimeInterval], now: TimeInterval) -> Size {
        guard let latest = phones.max(by: { $0.active < $1.active }) else { return .free }
        if let mac = macActivity.max(), now - mac < 60 { return .mac }
        return .phone(cols: latest.cols, rows: latest.rows)
    }

    /// A grid the PTY can be, whatever the phone sent.
    public static func clamp(cols: Int, rows: Int) -> (cols: Int, rows: Int) { (min(max(cols, 10), 500), min(max(rows, 4), 200)) }

    // MARK: Startup queries

    /// What tmux asks a new client (DA1, DA2, XTVERSION, the colour scheme, the foreground and background), answered
    /// from the Mac in the first seconds and kept out of what the phone gets, so SwiftTerm never answers twice.
    /// XTVERSION matters most: until it's answered tmux holds a lone Esc for 500 ms.
    public struct Queries: Sendable {
        private let answers: [(query: [UInt8], reply: [UInt8])]
        private var held: [UInt8] = []

        public init(dark: Bool = true, foreground: String = "rgb:ffff/ffff/ffff", background: String = "rgb:0000/0000/0000") {
            let esc = "\u{1B}", st = "\u{1B}\\", bel = "\u{07}"
            let da1 = esc + "[?62;22c", da2 = esc + "[>0;10;1c", version = esc + "P>|SideA-Remote 1.0" + st
            let scheme = esc + "[?997;\(dark ? 1 : 2)n"
            func osc(_ number: Int, _ colour: String) -> [(String, String)] {
                [(esc + "]\(number);?" + bel, esc + "]\(number);\(colour)" + bel), (esc + "]\(number);?" + st, esc + "]\(number);\(colour)" + st)]
            }
            let pairs: [(String, String)] = [(esc + "[c", da1), (esc + "[0c", da1), (esc + "[>c", da2), (esc + "[>0c", da2),
                                             (esc + "[>q", version), (esc + "[>0q", version), (esc + "[?996n", scheme)]
                + osc(10, foreground) + osc(11, background)
            answers = pairs.map { (Array($0.0.utf8), Array($0.1.utf8)) }
        }

        /// From the phone's hello; without one, a dark terminal, white on black.
        public init(theme: TermTheme?) {
            let dark = theme?.appearance != .light
            self.init(dark: dark, foreground: Self.colour(theme?.fg) ?? (dark ? "rgb:ffff/ffff/ffff" : "rgb:0000/0000/0000"),
                      background: Self.colour(theme?.bg) ?? (dark ? "rgb:0000/0000/0000" : "rgb:ffff/ffff/ffff"))
        }

        /// "#e6e6e6" as xterm answers a colour query, "rgb:e6e6/e6e6/e6e6"; nil for anything else.
        public static func colour(_ hex: String?) -> String? {
            guard let hex, hex.count == 7, hex.first == "#", hex.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
            let digits = Array(hex.dropFirst().lowercased())
            return "rgb:" + stride(from: 0, to: 6, by: 2).map { String(digits[$0...$0 + 1]) + String(digits[$0...$0 + 1]) }.joined(separator: "/")
        }

        /// The bytes to forward and the replies to write back to tmux. A query cut off at the end of a read is held
        /// until the next one.
        public mutating func filter(_ chunk: Data) -> (forward: Data, replies: Data) {
            let bytes = held + [UInt8](chunk)
            held = []
            var forward: [UInt8] = []
            var replies: [UInt8] = []
            var index = 0
            scanning: while index < bytes.count {
                guard bytes[index] == 0x1B else { forward.append(bytes[index]); index += 1; continue }
                let rest = bytes[index...]
                for (query, reply) in answers where rest.starts(with: query) {
                    replies += reply
                    index += query.count
                    continue scanning
                }
                if answers.contains(where: { $0.query.count > rest.count && $0.query.starts(with: rest) }) {
                    held = Array(rest)
                    break
                }
                forward.append(0x1B)
                index += 1
            }
            return (Data(forward), Data(replies))
        }

        /// Whatever was held when the query window closes.
        public mutating func flush() -> Data {
            defer { held = [] }
            return Data(held)
        }
    }
}
