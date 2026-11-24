@testable import SideA
import SideAProtocol
import Testing

private let colours = IslandQuestion(question: "Which colours?", header: nil, options: [
    .init(label: "Red (Recommended)", description: "Warm"), .init(label: "Green", description: "green"), .init(label: "Blue (Recommended)", description: nil),
], multiSelect: true)
private let size = IslandQuestion(question: "Which size?", header: nil, options: [
    .init(label: "Small", description: nil), .init(label: "Large (Recommended)", description: "The usual"),
], multiSelect: false)

@Test func answersFollowTheQuestionsOrderThenWhatWasTyped() {
    var answers = QuestionAnswers()
    answers.pick("Blue (Recommended)", in: colours)
    answers.pick("Green", in: colours)
    answers.pick("Red (Recommended)", in: colours)
    answers.pick("Green", in: colours)
    answers.other[colours.question] = "  teal \n"
    #expect(answers.answer(colours) == "Red (Recommended), Blue (Recommended), teal")
    answers.pick("Small", in: size)
    answers.pick("Large (Recommended)", in: size)
    #expect(answers.answer(size) == "Large (Recommended)")
    #expect(answers.answers([colours, size]) == [colours.question: "Red (Recommended), Blue (Recommended), teal", size.question: "Large (Recommended)"])
}

@Test func recommendedAnswersArePreselectedAndRecognised() {
    var answers = QuestionAnswers()
    answers.preselect([colours, size])
    #expect(answers.answer(size) == "Large (Recommended)")
    #expect(answers.picked[colours.question] == nil)
    #expect(!answers.complete([colours, size]) && !answers.recommendedOnly([colours, size]))
    answers.pick("Blue (Recommended)", in: colours)
    answers.pick("Red (Recommended)", in: colours)
    #expect(answers.complete([colours, size]) && answers.recommendedOnly([colours, size]))
    answers.other[size.question] = "Medium"
    #expect(!answers.recommendedOnly([colours, size]))
    var kept = QuestionAnswers()
    kept.pick("Small", in: size)
    kept.preselect([size])
    #expect(kept.answer(size) == "Small")
}

@Test func aDescriptionThatRepeatsItsLabelIsLeftOut() {
    #expect(QuestionAnswers.description(of: colours.options[0]) == "Warm")
    #expect(QuestionAnswers.description(of: colours.options[1]) == nil)
    #expect(QuestionAnswers.description(of: colours.options[2]) == nil)
}
