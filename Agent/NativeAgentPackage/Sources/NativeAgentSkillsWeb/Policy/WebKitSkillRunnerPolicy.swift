import NativeAgentSkills
import Foundation

/// Fail-closed policy for the local `run_js` execution surface.
///
/// This optional adapter executes only local, non-persistent scripts. Network,
/// secrets, host intents, native bridges, device access, persistent storage,
/// and external navigation remain explicit consuming-host responsibilities.
public struct WebKitSkillRunnerPolicy: Hashable, Sendable {
    public static let maximumInputBytes = 8 * 1_024 * 1_024
    public static let maximumOutputBytes = 8 * 1_024 * 1_024
    public static let maximumTimeout: Duration = .seconds(120)

    public let timeout: Duration
    public let maxInputBytes: Int
    public let maxOutputBytes: Int

    public init(
        timeout: Duration = .seconds(15),
        maxInputBytes: Int = 1_048_576,
        maxOutputBytes: Int = 1_048_576
    ) {
        self.timeout = min(max(timeout, .milliseconds(1)), Self.maximumTimeout)
        self.maxInputBytes = min(max(1, maxInputBytes), Self.maximumInputBytes)
        self.maxOutputBytes = min(max(1, maxOutputBytes), Self.maximumOutputBytes)
    }

    public static let localPure = WebKitSkillRunnerPolicy()

    func unsupportedCapabilities(
        for requirements: SkillCapabilityRequirements,
        exposesSecret: Bool
    ) -> [String] {
        var unsupported: [String] = []
        if exposesSecret { unsupported.append("secret") }
        if requirements.requiresNetwork { unsupported.append("network") }
        if requirements.requiresPersistentStorage { unsupported.append("persistent-storage") }
        if requirements.requiresCameraOrMicrophone { unsupported.append("camera-or-microphone") }
        if requirements.requiresExternalNavigation { unsupported.append("external-navigation") }
        if requirements.bridgeIntents.isEmpty == false {
            unsupported.append(
                "bridge-intents(\(requirements.bridgeIntents.sorted().joined(separator: ",")))"
            )
        }
        if requirements.hostIntents.isEmpty == false {
            unsupported.append(
                "host-intents(\(requirements.hostIntents.sorted().joined(separator: ",")))"
            )
        }
        return unsupported
    }
}
