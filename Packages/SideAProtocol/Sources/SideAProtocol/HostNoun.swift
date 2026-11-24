

/// What the phone calls the computer a host runs on. A Mac keeps the words it always had; anything else is "computer",
/// or its own name where the sentence can carry one. A kind this phone doesn't know reads as a computer.
extension HostOS {
    public var isMac: Bool { self == .macos }

    /// Mid-sentence: "Mac" or "computer".
    public var noun: String { isMac ? "Mac" : "computer" }
    /// Starting a title or sentence: "Mac" or "Computer".
    public var titleNoun: String { isMac ? "Mac" : "Computer" }
    /// Mid-sentence: "Macs" or "computers".
    public var plural: String { isMac ? "Macs" : "computers" }
    /// A title over a list that may mix kinds: "Macs" or "Computers".
    public var titlePlural: String { isMac ? "Macs" : "Computers" }

    /// "the Mac", or the host's `name` when it isn't a Mac and the sentence has one, else "the computer".
    public func the(_ name: String? = nil) -> String { isMac ? "the Mac" : name.flatMap { $0.isEmpty ? nil : $0 } ?? "the computer" }
    /// `the` opening a sentence: "The Mac", the host's `name`, or "The computer".
    public func sentenceThe(_ name: String? = nil) -> String { isMac ? "The Mac" : name.flatMap { $0.isEmpty ? nil : $0 } ?? "The computer" }
    /// "your Mac", or the host's `name` when it isn't a Mac and the sentence has one, else "your computer".
    public func your(_ name: String? = nil) -> String { isMac ? "your Mac" : name.flatMap { $0.isEmpty ? nil : $0 } ?? "your computer" }

    /// The key a Mac calls Command, which a Linux host calls Super and a Windows one the Windows key.
    public var superKeyName: String {
        switch self {
        case .macos: "Command"
        case .windows, .wsl: "Win"
        default: "Super"
        }
    }
}

extension Sequence<HostOS> {
    /// What to call hosts together ("Macs" or "Computers"): a Mac only when every one is a Mac.
    public var shared: HostOS {
        var first: HostOS?
        for kind in self where !kind.isMac { first = first ?? kind }
        return first ?? .macos
    }
}
