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
    ]
}
