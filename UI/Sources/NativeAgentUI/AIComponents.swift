import SwiftUI
@_exported import NativeAgentPresentation

public struct AgentUIProviderMark: View {
    @Environment(\.agentUIStyle) private var style
    public init(provider: AgentUIProvider, color: Color) {
        self.provider = provider
        self.color = color
    }
    let provider: AgentUIProvider
    let color: Color

    public var body: some View {
        ZStack {
            Image(systemName: provider.symbol)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(color)

            // Artwork semantics are supplied by the host provider descriptor.
            if let decoration = provider.decorationSymbol {
                Image(systemName: decoration)
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(color)
                    .offset(y: -1)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

struct AgentUIUsageRing<Center: View>: View {
    @Environment(\.agentUIStyle) private var style
    let status: AgentUIStatus
    let size: CGFloat
    let center: Center

    init(
        status: AgentUIStatus,
        size: CGFloat,
        @ViewBuilder center: () -> Center
    ) {
        self.status = status
        self.size = size
        self.center = center()
    }

    var body: some View {
        ZStack {
            // The 20% opening is centered at the bottom. The progress begins
            // at the lower-left edge and ends at the lower-right edge.
            Circle()
                .trim(from: 0.10, to: 0.90)
                .stroke(style.rule, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                .rotationEffect(.degrees(90))

            if let remaining = status.usageRemainingPercent, status.usageState == .ready {
                Circle()
                    .trim(from: 0.10, to: 0.10 + 0.80 * CGFloat(remaining) / 100)
                    .stroke(
                        style.usageColor(remaining),
                        style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(90))
            }

            center
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var strokeWidth: CGFloat { max(2, size * 0.085) }
}

struct AgentUIProviderButton: View {
    @Environment(\.agentUIStyle) private var style
    let provider: AgentUIProvider
    let status: AgentUIStatus
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AgentUIProviderStatusBadge(provider: provider, status: status)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(provider.accessibilityTitle)
        .accessibilityValue(providerState.title)
        .accessibilityHint(providerState == .ready ? "연결됨" : "AI 설정 열기")
        .accessibilityIdentifier("\(accessibilityIdentifier).provider.\(provider.id)")
    }

    private var providerState: AgentUIConnectionState {
        status.state(for: provider)
    }

    private var statusColor: Color {
        style.statusColor(providerState)
    }
}

struct AgentUIProviderStatusBadge: View {
    @Environment(\.agentUIStyle) private var style
    let provider: AgentUIProvider
    let status: AgentUIStatus

    var body: some View {
        if provider.id == status.usageProvider?.id {
            // Only the explicitly selected quota owner receives a usage ring.
            AgentUIUsageRing(status: status, size: 48) {
                AgentUIProviderMark(provider: provider, color: statusColor)
            }
        } else {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.10))
                Circle()
                    .stroke(statusColor.opacity(0.45), lineWidth: 2)
                AgentUIProviderMark(provider: provider, color: statusColor)
                    .scaleEffect(1.1)
            }
            .frame(width: 48, height: 48)
        }
    }

    private var providerState: AgentUIConnectionState {
        status.state(for: provider)
    }

    private var statusColor: Color {
        style.statusColor(providerState)
    }
}

public struct AgentUIProviderUsageBadge: View {
    @Environment(\.agentUIStyle) private var style
    public init(status: AgentUIStatus, size: CGFloat) {
        self.status = status
        self.size = size
    }
    let status: AgentUIStatus
    let size: CGFloat

    public var body: some View {
        if let primaryProvider {
            AgentUIProviderStatusBadge(provider: primaryProvider, status: status)
                .scaleEffect(size / 48)
        }
    }

    private var primaryProvider: AgentUIProvider? {
        status.providers.first { $0.state == .ready }?.provider ?? status.providers.first?.provider
    }
}

struct AgentUIStatusLight: View {
    @Environment(\.agentUIStyle) private var style
    let status: AgentUIConnectionState

    var body: some View {
        VStack(spacing: 1.5) {
            light(style.unavailable, active: status == .unavailable)
            light(style.attention, active: [.setupRequired, .checking, .working].contains(status))
            light(style.ready, active: status == .ready)
        }
        .padding(.horizontal, 2.5)
        .padding(.vertical, 3)
        .background(style.foreground.opacity(0.07), in: Capsule())
        .overlay { Capsule().stroke(style.rule, lineWidth: 0.75) }
        .accessibilityHidden(true)
    }

    private func light(_ color: Color, active: Bool) -> some View {
        Circle()
            .fill(active ? color : style.secondaryForeground.opacity(0.16))
            .frame(width: 5.5, height: 5.5)
    }
}

public struct AgentUIStatusRail: View {
    @Environment(\.agentUIStyle) private var style
    public init(status: AgentUIStatus, accessibilityIdentifier: String) {
        self.status = status
        self.accessibilityIdentifier = accessibilityIdentifier
    }
    let status: AgentUIStatus
    let accessibilityIdentifier: String

    public var body: some View {
        HStack(spacing: 8) {
            ForEach(status.providers) { item in
                providerItem(item.provider, state: item.state,
                             identifier: "\(accessibilityIdentifier).\(item.id)")
            }
            if status.usageProvider != nil { usageItem }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(style.raisedSurface, in: RoundedRectangle(cornerRadius: style.cardRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: style.cardRadius, style: .continuous).stroke(style.rule, lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func providerItem(
        _ provider: AgentUIProvider,
        state: AgentUIConnectionState,
        identifier: String
    ) -> some View {
        HStack(spacing: 5) {
            AgentUIProviderMark(provider: provider, color: style.statusColor(state))
                .scaleEffect(0.78)
            Text(provider.title)
                .font(style.smallCaption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 2)
            AgentUIStatusLight(status: state)
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(provider.accessibilityTitle)
        .accessibilityValue(state.title)
        .accessibilityIdentifier(identifier)
    }

    private var usageItem: some View {
        AgentUIUsageIndicator(status: status, accessibilityIdentifier: "\(accessibilityIdentifier).usage")
    }
}

/// The existing provider-owned usage ring and percentage, reusable without
/// coupling the independent SDK to an application's settings layout.
public struct AgentUIUsageIndicator: View {
    @Environment(\.agentUIStyle) private var style
    private let status: AgentUIStatus
    private let accessibilityIdentifier: String

    public init(status: AgentUIStatus, accessibilityIdentifier: String) {
        self.status = status
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var body: some View {
        VStack(spacing: 1) {
            AgentUIUsageRing(status: status, size: 33) {
                Image(systemName: usageBatterySymbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(usageColor)
            }
            Text(usageLabel)
                .font(style.smallCaption.weight(.semibold).monospacedDigit())
                .foregroundStyle(usageColor)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 42)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(status.usageProvider?.title ?? "AI") 사용량")
        .accessibilityValue(status.usageDescription)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var usageLabel: String {
        guard status.usageState == .ready else { return "—" }
        guard let remaining = status.usageRemainingPercent else { return "…" }
        return "\(remaining)%"
    }

    private var usageColor: Color {
        guard status.usageState == .ready else { return style.statusColor(status.usageState) }
        return style.usageColor(status.usageRemainingPercent)
    }

    private var usageBatterySymbol: String {
        guard let remaining = status.usageRemainingPercent, status.usageState == .ready else { return "battery.100" }
        switch remaining {
        case 0: return "battery.0"
        case 1..<25: return "battery.25"
        case 25..<50: return "battery.50"
        case 50..<80: return "battery.75"
        default: return "battery.100"
        }
    }
}

// MARK: - AI 작업

