import Foundation

public struct ConsensusResponseRenderer: Sendable {
    private let closure: @Sendable (BACResult) -> String

    public init(_ closure: @escaping @Sendable (BACResult) -> String) {
        self.closure = closure
    }

    public func render(_ result: BACResult) -> String {
        closure(result)
    }

    public static let concise = ConsensusResponseRenderer { result in
        let final = result.final
        var lines: [String] = []
        lines.append("Decision: \(final.decision.rawValue)")
        if !final.summary.isEmpty {
            lines.append("Summary: \(final.summary)")
        }

        if !final.selectedPlan.isEmpty {
            lines.append("Plan:")
            for action in final.selectedPlan {
                lines.append("- \(action.label)")
            }
        }

        if !final.requiredActions.isEmpty {
            lines.append("Required actions:")
            for action in final.requiredActions {
                lines.append("- \(action.label)")
            }
        }

        if !final.blockers.isEmpty {
            lines.append("Blockers:")
            for blocker in final.blockers {
                lines.append("- \(blocker.label)")
            }
        }

        if !final.checks.isEmpty {
            lines.append("Checks:")
            for check in final.checks {
                lines.append("- \(check.label)")
            }
        }

        if !final.saferOption.isEmpty {
            lines.append("Safer option: \(final.saferOption)")
        }

        return lines.joined(separator: "\n")
    }
}
