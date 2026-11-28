import Foundation
import Observation
import SideAProtocol
import SideARemoteKit

/// The checkpoints one host keeps of another computer's sessions (`GET /v1/standby`), read when its moves are. Nothing runs
/// from them until one is continued here as a copy.
@Observable
final class StandbyCopies {
    nonisolated deinit {}

    private(set) var copies: [StandbyCopy] = []

    /// A copy asked for and not answered goes again under the same key, so the host answers from the first if it landed.
    @ObservationIgnored var key = SendKey<String>()
    @ObservationIgnored var demo: DemoStandby?

    func copy(_ conversation: String) -> StandbyCopy? { copies.first { $0.conversationID == conversation } }

    func set(_ copies: [StandbyCopy]) { if self.copies != copies { self.copies = copies } }
}

enum StandbyText {
    static func title(_ copy: StandbyCopy) -> String { copy.title ?? copy.project ?? "Session" }

    static func from(_ copy: StandbyCopy) -> String { "From \(copy.computerName)" }

    /// The one thing that matters before a copy: the computer it came from may still be running the original.
    static func warning(_ copy: StandbyCopy) -> String {
        "If \(copy.computerName) is still running this session, both will work, and anything they do outside the repository happens twice."
    }
}
