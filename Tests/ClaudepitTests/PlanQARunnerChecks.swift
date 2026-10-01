import Foundation
@testable import ClaudepitCore

func planQARunnerChecks() -> [Bool] {
    [
        check("buildPrompt_noHistory") {
            let prompt = PlanQARunner.buildPrompt(
                planContent: "# Plan\nDo X then Y.",
                history: [],
                question: "What does step 1 do?"
            )
            try expect(prompt.contains("<plan>"), "missing <plan> tag")
            try expect(prompt.contains("Do X then Y."), "missing plan content")
            try expect(prompt.contains("What does step 1 do?"), "missing question")
            try expect(!prompt.contains("Previous conversation:"), "should have no history block")
        },
        check("buildPrompt_withHistory") {
            let history: [QAMessage] = [
                QAMessage(role: "user", text: "First question"),
                QAMessage(role: "assistant", text: "First answer"),
            ]
            let prompt = PlanQARunner.buildPrompt(
                planContent: "# Plan",
                history: history,
                question: "Second question"
            )
            try expect(prompt.contains("Previous conversation:"), "missing history header")
            try expect(prompt.contains("User: First question"), "missing user turn")
            try expect(prompt.contains("Assistant: First answer"), "missing assistant turn")
            try expect(prompt.contains("Question: Second question"), "missing final question")
        },
        check("buildPrompt_rewritesOnlyWhereOffered") {
            let plan = PlanQARunner.buildPrompt(planContent: "x", history: [], question: "q")
            try expect(plan.contains("[[SUGGEST_IMPROVEMENT]]"), "a plan is offered rewrites, as before")
            let spec = PlanQARunner.buildPrompt(planContent: "x", history: [], question: "q", contentLabel: "spec")
            try expect(!spec.contains("[[SUGGEST_IMPROVEMENT]]"), "other content isn't, unless asked")
            let loop = PlanQARunner.buildPrompt(planContent: "x", history: [], question: "q", contentLabel: "loop.md",
                                                about: "It is what a bare /loop runs.", suggestsImprovements: true)
            try expect(loop.contains("would improve the loop.md"), "names its own content: \(loop)")
            try expect(loop.contains("It is what a bare /loop runs."), "says what the content is")
            let rewrite = PlanQARunner.buildImprovementPrompt(planContent: "x", suggestion: "y", subject: "loop.md")
            try expect(rewrite.hasPrefix("You are rewriting a loop.md"), "names the subject: \(rewrite)")
        },
    ]
}
