import SideARemoteShared

/// Why a terminal stopped. Only `.exited` is a process ending; the rest are refusals the person can act on,
/// so the screen must not title them all "Process Exited".
enum TerminalEnd: Equatable {
    case exited(killed: Bool)
    case notUnlocked
    case unpaired
    case outdated
    case tooManyScreens

    /// The session's own close codes: ended (4410, 4404), unpaired, outdated, too many screens. Others are a dropped socket.
    init?(closeCode code: Int) {
        switch code {
        case 4410, 4404: self = .exited(killed: false)
        case 4401: self = .unpaired
        case 4426: self = .outdated
        case 4409: self = .tooManyScreens
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .exited: "Process Exited"
        case .notUnlocked: "Terminal Locked"
        case .unpaired: "Not Paired"
        case .outdated: "Update Needed"
        case .tooManyScreens: "Open Elsewhere"
        }
    }

    var systemImage: String {
        switch self {
        case .exited: "xmark.octagon"
        case .notUnlocked: "lock"
        case .unpaired: "link.badge.plus"
        case .outdated: "arrow.down.circle"
        case .tooManyScreens: "rectangle.on.rectangle"
        }
    }

    /// Retrying can help only when the refusal was this device's unlock or a screen limit someone can free.
    var canRetry: Bool { self == .notUnlocked || self == .tooManyScreens }

    var message: String {
        switch self {
        case .exited(let killed): killed ? "The session was ended." : "The session ended."
        case .notUnlocked:
            Biometry.current == .passcode ? "Your passcode is needed to use the terminal."
                                          : "\(Biometry.current.name) or your passcode is needed to use the terminal."
        case .unpaired: "This \(ThisDevice.kind) isn't paired anymore."
        case .outdated: "Update Side A to use the terminal."
        case .tooManyScreens: "Open on too many screens. Close one and try again."
        }
    }
}
