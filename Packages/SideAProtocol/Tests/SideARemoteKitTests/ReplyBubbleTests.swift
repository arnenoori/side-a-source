import SideAProtocol
import SideARemoteKit
import Testing

private typealias B = ReplyBubble
private typealias Stage = ReplyProgress.Stage

private let stages: [Stage] = Stage.allCases.filter { ![.unsent, .withdrawn].contains($0) }
private let watches: [B.Watch] = [.receipts, .unchecked, .carried(with: "w", unchecked: false), .carried(with: "w", unchecked: true), .shownAway]

@Test func aBubblesStageFollowsReplyProgress() {
    for stage in stages {
        for watch in watches where watch != .shownAway {
            let bubble = B(stage, watch: watch)
            for event in ReplyProgress.Event.allCases {
                let expected: B.Next? = switch ReplyProgress(stage).next(event)?.stage {
                case nil, stage?: nil
                case .unsent?: .returns
                case .withdrawn?: .leaves
                case let to?: .stays(B(to, watch: watch))
                }
                #expect(bubble.next(.progress(event)) == expected, "\(stage) \(watch) \(event)")
            }
            for to in Stage.allCases {
                let moves = to != stage && ![.unsent, .withdrawn].contains(to) && ReplyProgress.moves(stage, to: to)
                #expect(bubble.next(.reached(to)) == (moves ? .stays(B(to, watch: watch)) : nil), "\(stage) \(watch) to \(to)")
            }
        }
    }
}

@Test func aShownAwayBubbleOnlyComesBackOrIsForgotten() {
    for stage in stages {
        let bubble = B(stage, watch: .shownAway)
        for event in ReplyProgress.Event.allCases {
            let back = ReplyProgress(stage).next(event)?.stage == .unsent
            #expect(bubble.next(.progress(event)) == (back ? .returns : nil), "\(stage) \(event)")
        }
        for to in Stage.allCases { #expect(bubble.next(.reached(to)) == nil) }
    }
}

// Every watch × event, for a stage of each kind: still sending, waiting on a receipt, queued, and read.
@Test func everyWatchEventFromEveryWatch() {
    let events: [B.Event] = [.gaveBack, .withdrawn, .receiptsLost, .carry(with: "x"), .uncarry,
                             .restarted(withSending: true, received: false), .restarted(withSending: true, received: true),
                             .restarted(withSending: false, received: false), .shown(bound: true), .shown(bound: false), .forgotten]
    func s(_ stage: Stage, _ watch: B.Watch) -> B.Next { .stays(B(stage, watch: watch)) }
    let r = B.Next.returns, l = B.Next.leaves
    let away = B.Watch.shownAway, plain = B.Watch.receipts, unchecked = B.Watch.unchecked
    let w = B.Watch.carried(with: "w", unchecked: false), wu = B.Watch.carried(with: "w", unchecked: true)
    let x = B.Watch.carried(with: "x", unchecked: false), xu = B.Watch.carried(with: "x", unchecked: true)
    let table: [(B, [B.Next?])] = [
        (B(.sending), [r, l, nil, nil, nil, nil, nil, nil, nil, nil, nil]),
        (B(.sent), [r, l, s(.sent, unchecked), s(.sent, x), nil, nil, nil, nil, s(.sent, away), l, nil]),
        (B(.queued), [r, l, nil, nil, nil, nil, nil, nil, s(.queued, away), l, nil]),
        (B(.read), [r, l, nil, nil, nil, nil, nil, nil, l, l, nil]),

        (B(.sending, watch: unchecked), [r, l, nil, nil, nil, nil, nil, nil, nil, nil, nil]),
        (B(.held, watch: unchecked), [r, l, nil, s(.held, xu), nil, nil, nil, nil, s(.held, away), l, nil]),
        (B(.queued, watch: unchecked), [r, l, nil, nil, nil, nil, nil, nil, s(.queued, away), l, nil]),
        (B(.read, watch: unchecked), [r, l, nil, nil, nil, nil, nil, nil, l, l, nil]),

        (B(.sending, watch: w), [r, l, nil, s(.sending, plain), s(.sending, plain), s(.sending, plain), s(.sending, plain), s(.sending, plain),
                                 nil, nil, nil]),
        (B(.sent, watch: w), [r, l, s(.sent, wu), s(.sent, x), s(.sent, plain), r, s(.sent, plain), s(.sent, plain), s(.sent, away), l, nil]),
        (B(.queued, watch: w), [r, l, nil, s(.queued, plain), s(.queued, plain), s(.queued, plain), s(.queued, plain), s(.queued, plain),
                                s(.queued, away), l, nil]),
        (B(.read, watch: w), [r, l, nil, s(.read, plain), s(.read, plain), s(.read, plain), s(.read, plain), s(.read, plain), l, l, nil]),

        (B(.sending, watch: wu), [r, l, nil, s(.sending, unchecked), s(.sending, unchecked), s(.sending, unchecked), s(.sending, unchecked),
                                  s(.sending, unchecked), nil, nil, nil]),
        (B(.held, watch: wu), [r, l, nil, s(.held, xu), s(.held, unchecked), r, s(.held, unchecked), s(.held, unchecked), s(.held, away), l, nil]),
        (B(.queued, watch: wu), [r, l, nil, s(.queued, unchecked), s(.queued, unchecked), s(.queued, unchecked), s(.queued, unchecked),
                                 s(.queued, unchecked), s(.queued, away), l, nil]),
        (B(.read, watch: wu), [r, l, nil, s(.read, unchecked), s(.read, unchecked), s(.read, unchecked), s(.read, unchecked), s(.read, unchecked),
                               l, l, nil]),

        (B(.sent, watch: away), [nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, l]),
        (B(.read, watch: away), [nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, l]),
    ]
    for (state, row) in table {
        for (event, expected) in zip(events, row) { #expect(state.next(event) == expected, "\(state) \(event)") }
    }
    #expect(B(.sent, watch: w).next(.carry(with: "w")) == nil)
}

@Test func onlyASentOrHeldBubbleReadsAsUnchecked() {
    for stage in stages {
        for watch in watches {
            let expected = [.sent, .held].contains(stage) && [B.Watch.unchecked, .carried(with: "w", unchecked: true)].contains(watch)
            #expect(B(stage, watch: watch).unchecked == expected, "\(stage) \(watch)")
        }
    }
    // A receipt that moves an unchecked bubble on keeps what it watches, which the stage then no longer asks.
    #expect(B(.sent, watch: .unchecked).next(.progress(.read)) == .stays(B(.read, watch: .unchecked)))
}
