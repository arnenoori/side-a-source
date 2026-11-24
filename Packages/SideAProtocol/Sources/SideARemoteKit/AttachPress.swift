import CoreGraphics
import Foundation

public enum AttachPress: Sendable, Equatable {
    case idle
    case down(CGPoint)
    case held
    case cancelled

    public enum Event: Sendable, Equatable {
        case moved(start: CGPoint, to: CGPoint)
        case heldLong
        case gaveUp
        case lifted
        case lost
    }

    public enum Effect: Sendable, Equatable {
        case pressBegins
        case cancelHold
        case showStrip
        case track(CGPoint)
        case tap
        case release
        case stopTracking
        case pressEnds
    }

    public static let slop: CGFloat = 14

    public func next(_ event: Event) -> (state: Self, effects: [Effect]) {
        switch (self, event) {
        case (.idle, .moved(let start, _)): (.down(start), [.pressBegins])
        case (.down(let start), .moved(_, let to)):
            hypot(to.x - start.x, to.y - start.y) > Self.slop ? (.cancelled, [.cancelHold]) : (self, [])
        case (.held, .moved(_, let to)): (self, [.track(to)])
        case (.down, .heldLong): (.held, [.showStrip])
        // VoiceOver's Recent Photos holds with no finger down: nothing to wait for, or the next touch would be swallowed.
        case (.idle, .gaveUp): (self, [])
        case (_, .gaveUp): (.cancelled, [])
        case (.down, .lifted): (.idle, [.cancelHold, .pressEnds, .tap])
        case (.held, .lifted): (.idle, [.cancelHold, .pressEnds, .release])
        case (.idle, .lifted), (.cancelled, .lifted): (.idle, [.cancelHold, .pressEnds])
        case (.idle, .lost): (self, [])
        case (.held, .lost): (.idle, [.cancelHold, .stopTracking, .pressEnds])
        case (.down, .lost), (.cancelled, .lost): (.idle, [.cancelHold, .pressEnds])
        case (.cancelled, .moved), (.idle, .heldLong), (.held, .heldLong), (.cancelled, .heldLong): (self, [])
        }
    }
}
