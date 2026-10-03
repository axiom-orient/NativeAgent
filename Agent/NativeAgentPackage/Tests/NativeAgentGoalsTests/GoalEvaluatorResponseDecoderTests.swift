import Testing
@testable import NativeAgentGoals

@Test
func goalJudgeResponseDecoderSkipsNonSchemaObjectsAndPreservesStringBraces() throws {
    let response = try GoalJudgeResponseDecoder().decode(
        """
        preface {"note":"not the judge schema"}
        {"satisfied":true,"blocked":false,"score":0.82,"reason":"contains } and \\"quoted\\" braces { safely","next_instruction":"done"}
        """
    )

    #expect(response.satisfied)
    #expect(!response.blocked)
    #expect(response.score == 0.82)
    #expect(response.reason == "contains } and \"quoted\" braces { safely")
    #expect(response.nextInstruction == "done")
}

@Test
func goalJudgeResponseDecoderRejectsResponsesWithoutTheRequiredSchema() {
    #expect(throws: GoalError.self) {
        try GoalJudgeResponseDecoder().decode(
            "prefix {\"satisfied\":true} suffix {\"score\":0.9}"
        )
    }
}
