import Foundation
import SideAProtocol

extension RemoteSuggestion {
    /// What a phone is shown for a rule the agent suggested: its id and title, and whether it lasts past the session.
    public init(_ suggestion: IslandSuggestion) {
        let scope: SuggestionScope? = switch suggestion.destination {
        case "session": .session
        case .some: .saved
        case nil: nil
        }
        self.init(id: RemoteAnswers.suggestionID(suggestion), title: suggestion.title, scope: scope)
    }
}
