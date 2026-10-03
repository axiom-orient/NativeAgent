import SwiftUI
import NativeAgentPresentation

/// Per-tree appearance. Defaults follow the system; a host may supply its own
/// semantic colors, type scale and layout without coupling the package to it.
public struct AgentUIStyle: Sendable {
    public var foreground: Color = .primary
    public var secondaryForeground: Color = .secondary
    public var ready: Color = .green
    public var attention: Color = .orange
    public var unavailable: Color = .red
    public var unknown: Color = .secondary
    public var rule: Color = .primary.opacity(0.13)
    public var surface: Color = .primary.opacity(0.055)
    public var raisedSurface: Color = .primary.opacity(0.035)
    public var title: Font = .title2
    public var subtitle: Font = .title3
    public var headline: Font = .headline
    public var subheadline: Font = .subheadline
    public var body: Font = .body
    public var caption: Font = .caption
    public var smallCaption: Font = .caption2
    public var pageInset: CGFloat = 20
    public var sectionSpacing: CGFloat = 16
    public var cardRadius: CGFloat = 18
    public var maximumWidth: CGFloat = 640
    public var selectionAnimation: Animation? = .easeInOut(duration: 0.18)

    public init() {}

    public func statusColor(_ status: AgentUIConnectionState) -> Color {
        switch status {
        case .ready: ready
        case .setupRequired, .checking, .working: attention
        case .unavailable: unavailable
        }
    }

    public func usageColor(_ remaining: Int?) -> Color {
        guard let remaining else { return unknown }
        switch remaining {
        case 50...: return ready
        case 20..<50: return attention
        default: return unavailable
        }
    }
}

private struct AgentUIStyleKey: EnvironmentKey {
    static let defaultValue = AgentUIStyle()
}

public extension EnvironmentValues {
    var agentUIStyle: AgentUIStyle {
        get { self[AgentUIStyleKey.self] }
        set { self[AgentUIStyleKey.self] = newValue }
    }
}

public extension View {
    func agentUIStyle(_ style: AgentUIStyle) -> some View {
        environment(\.agentUIStyle, style)
    }
}
