import Foundation

enum TutorInsightMarkdownFormatter {
    static func narrative(prompt: String, reply: TutorReply) -> String {
        var lines: [String] = ["# \(reply.title)", "", "## Prompt", "", prompt, "", "## Summary", "", reply.summary]
        if !reply.sections.isEmpty {
            for section in reply.sections {
                lines.append(contentsOf: ["", "## \(section.heading)", "", section.body])
            }
        }
        if !reply.comprehensionChecks.isEmpty {
            lines.append(contentsOf: ["", "## Comprehension checks", ""])
            lines.append(contentsOf: reply.comprehensionChecks.map { "- \($0)" })
        }
        if !reply.followUpPrompts.isEmpty {
            lines.append(contentsOf: ["", "## Follow-up prompts", ""])
            lines.append(contentsOf: reply.followUpPrompts.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    static func practiceSet(_ practiceSet: TutorPracticeSet) -> String {
        var lines: [String] = ["# Practice set: \(practiceSet.topic)"]
        if !practiceSet.recap.isEmpty {
            lines.append(contentsOf: ["", "## Recap", ""])
            lines.append(contentsOf: practiceSet.recap.map { "- \($0)" })
        }
        for (index, question) in practiceSet.questions.enumerated() {
            lines.append(contentsOf: [
                "",
                "## Question \(index + 1)",
                "",
                question.prompt,
                "",
                "### Ideal answer",
                "",
                question.idealAnswer
            ])
            if !question.hints.isEmpty {
                lines.append(contentsOf: ["", "### Hints", ""])
                lines.append(contentsOf: question.hints.map { "- \($0)" })
            }
            if !question.conceptIDs.isEmpty {
                lines.append(contentsOf: ["", "### Concepts", "", "- " + question.conceptIDs.joined(separator: ", ")])
            }
        }
        return lines.joined(separator: "\n")
    }

    static func practiceEvaluation(practiceSet: TutorPracticeSet, evaluation: TutorPracticeEvaluation) -> String {
        var lines: [String] = [
            "# Practice evaluation: \(practiceSet.topic)",
            "",
            "## Summary",
            "",
            evaluation.summary,
            "",
            "## Overall score",
            "",
            String(format: "%.2f", evaluation.overallScore)
        ]
        for result in evaluation.itemResults {
            let score = String(format: "%.2f", result.score)
            lines.append(contentsOf: [
                "",
                "## \(result.questionID)",
                "",
                "- Verdict: \(result.verdict)",
                "- Score: \(score)",
                "",
                result.feedback
            ])
            if !result.expectedPoints.isEmpty {
                lines.append(contentsOf: ["", "### Expected points", ""])
                lines.append(contentsOf: result.expectedPoints.map { "- \($0)" })
            }
            if !result.conceptIDs.isEmpty {
                lines.append(contentsOf: ["", "### Concepts", "", "- " + result.conceptIDs.joined(separator: ", ")])
            }
        }
        if !evaluation.recommendedFocusTopics.isEmpty {
            lines.append(contentsOf: ["", "## Recommended focus topics", ""])
            lines.append(contentsOf: evaluation.recommendedFocusTopics.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    static func studyPlan(_ plan: TutorStudyPlan) -> String {
        var lines: [String] = ["# \(plan.headline)"]
        if !plan.focusTopics.isEmpty {
            lines.append(contentsOf: ["", "## Focus topics", ""])
            lines.append(contentsOf: plan.focusTopics.map { "- \($0)" })
        }
        if !plan.actions.isEmpty {
            lines.append(contentsOf: ["", "## Actions", ""])
            lines.append(contentsOf: plan.actions.map { "- \($0)" })
        }
        if !plan.rationale.isEmpty {
            lines.append(contentsOf: ["", "## Rationale", ""])
            lines.append(contentsOf: plan.rationale.map { "- \($0)" })
        }
        if !plan.dueConceptIDs.isEmpty {
            lines.append(contentsOf: ["", "## Due concepts", ""])
            lines.append(contentsOf: plan.dueConceptIDs.map { "- \($0)" })
        }
        if !plan.knowledgeMaintenance.isEmpty {
            lines.append(contentsOf: ["", "## Knowledge maintenance", ""])
            lines.append(contentsOf: plan.knowledgeMaintenance.map { "- [\($0.kind)] \($0.summary)" })
        }
        return lines.joined(separator: "\n")
    }
}
