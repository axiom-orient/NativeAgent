import KnowledgeCore

/// Pure construction and validation of human patch decisions.
enum ASKPatchDecisionFactory {
  static func makeReceipt(
    for plan: KnowledgePatchPlan,
    decision: PatchDecision,
    decidedBy: String,
    decidedAt: String,
    reason: String? = nil,
    selectedOptionID: String? = nil
  ) throws -> PatchDecisionReceipt {
    let selected = try selectedOptionID.map {
      try PatchChoiceID(validating: $0, field: "selected_option_id")
    }
    let receipt = PatchDecisionReceipt(
      version: patchDecisionReceiptVersion,
      patchID: plan.patchID,
      decision: decision,
      decidedBy: decidedBy,
      decidedAt: decidedAt,
      reason: reason
        ?? (decision == .approved ? "human approved patch" : "human rejected patch"),
      selectedOptionID: selected?.rawValue
    )
    try receipt.validate()
    return receipt
  }

  static func makeReceipt(
    for plan: KnowledgePatchPlan,
    choice: String,
    decidedBy: String,
    decidedAt: String,
    reason: String? = nil
  ) throws -> PatchDecisionReceipt {
    let choiceID = try PatchChoiceID(validating: choice, field: "choice")
    return try makeReceipt(
      for: plan,
      decision: choiceID.decision,
      decidedBy: decidedBy,
      decidedAt: decidedAt,
      reason: reason
        ?? (choiceID == .approve
          ? "human selected correction"
          : "human rejected ambiguous correction"),
      selectedOptionID: choiceID.rawValue
    )
  }
}
