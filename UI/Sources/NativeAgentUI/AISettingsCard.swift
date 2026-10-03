import SwiftUI
import NativeAgentPresentation

/// Provider-neutral settings composition. Hosts supply controls and effects;
/// the shared card renders identity, readiness and externally styled content.
public struct AgentUISettingsCard<Content: View>: View {
    @Environment(\.agentUIStyle) private var style
    private let provider: AgentUIProvider
    private let state: AgentUIConnectionState
    private let subtitle: String
    private let content: Content

    public init(provider: AgentUIProvider, state: AgentUIConnectionState,
                subtitle: String = "", @ViewBuilder content: () -> Content) {
        self.provider = provider
        self.state = state
        self.subtitle = subtitle
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AgentUIProviderMark(provider: provider, color: style.statusColor(state))
                    .frame(width: 42, height: 42)
                    .background(style.statusColor(state).opacity(0.11), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(provider.title).font(style.headline.weight(.semibold))
                        Text(state.title)
                            .font(style.smallCaption.weight(.semibold))
                            .foregroundStyle(style.statusColor(state))
                    }
                    if !subtitle.isEmpty {
                        Text(subtitle).font(style.subheadline).foregroundStyle(style.secondaryForeground)
                    }
                }
                Spacer(minLength: 0)
            }
            content
        }
        .padding(style.sectionSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.raisedSurface, in: RoundedRectangle(cornerRadius: style.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: style.cardRadius).stroke(style.rule, lineWidth: 1) }
    }
}
