/// Hard support envelope for the intentionally small, whole-value goal store.
///
/// Goal state is rewritten atomically after each turn. Keeping this envelope
/// explicit prevents that simple design from becoming an unbounded quadratic
/// write path. Long transcripts belong in the incremental session store.
public enum GoalResourceLimits {
    public static let maximumTurns = 128
    public static let maximumStoredGoals = 512
    public static let maximumGoalFileBytes = 16 * 1_024 * 1_024

    public static let maximumIdentifierUTF8Bytes = 512
    public static let maximumObjectiveUTF8Bytes = 32 * 1_024
    public static let maximumSuccessConditionUTF8Bytes = 32 * 1_024
    public static let maximumTurnOutputUTF8Bytes = 64 * 1_024
    public static let maximumReasonUTF8Bytes = 16 * 1_024
    public static let maximumInstructionUTF8Bytes = 16 * 1_024
    public static let maximumErrorUTF8Bytes = 16 * 1_024
}
