import Foundation

extension RuntimeConfiguration {
    /// Canonical default used by the high-level `Agent` facade.
    public static let agentDefault = RuntimeConfiguration(
        safetyPolicy: .durable
    )
}
