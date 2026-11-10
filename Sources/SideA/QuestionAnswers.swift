import SideAProtocol

/// What's picked on an AskUserQuestion form, and the answers that go back to Claude Code. The island and the
/// Sessions window each lay the form out their own way and answer through this.
struct QuestionAnswers: Equatable {
    var picked: [String: Set<String>] = [:]
    var other: [String: String] = [:]

    func isPicked(_ label: String, in question: IslandQuestion) -> Bool { picked[question.question]?.contains(label) == true }

    /// A single choice replaces the last; on a multiple choice each pick toggles.
    mutating func pick(_ label: String, in question: IslandQuestion) {
        guard question.multiSelect else { return picked[question.question] = [label] }
        var chosen = picked[question.question] ?? []
        if chosen.remove(label) == nil { chosen.insert(label) }
        picked[question.question] = chosen
    }

    /// The picked options in the order the question lists them, then anything typed.
    func answer(_ question: IslandQuestion) -> String {
        question.answerText(picked: question.options.map(\.label).filter { isPicked($0, in: question) }, other: other[question.question])
    }

    func answers(_ questions: [IslandQuestion]) -> [String: String] {
        Dictionary(questions.map { ($0.question, answer($0)) }) { first, _ in first }
    }

    func complete(_ questions: [IslandQuestion]) -> Bool { questions.allSatisfy { !answer($0).isEmpty } }

    /// Every answer is still the one Claude recommended, so one click accepts them all.
    func recommendedOnly(_ questions: [IslandQuestion]) -> Bool {
        questions.allSatisfy { question in
            let recommended = Set(question.options.filter(\.recommended).map(\.label))
            return !recommended.isEmpty && picked[question.question] == recommended && (other[question.question] ?? "").isEmpty
        }
    }

    /// Starts each single-choice question on Claude's recommended answer.
    mutating func preselect(_ questions: [IslandQuestion]) {
        for question in questions where !question.multiSelect && picked[question.question] == nil {
            if let option = question.options.first(where: \.recommended) { picked[question.question] = [option.label] }
        }
    }

    /// An option's description, unless it only repeats the label.
    static func description(of option: IslandQuestion.Option) -> String? {
        guard let description = option.description, !description.isEmpty, description.caseInsensitiveCompare(option.label) != .orderedSame else { return nil }
        return description
    }
}
