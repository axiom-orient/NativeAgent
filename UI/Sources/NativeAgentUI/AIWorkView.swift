import SwiftUI
import NativeAgentPresentation

/// Reusable work surface. The host supplies target context and execution
/// callbacks; this view owns the hierarchy, state language, and recovery route.
public struct AgentUIWorkView: View {
    @Environment(\.agentUIStyle) private var style
    public let status: AgentUIStatus
    public let target: AgentUIWorkTarget
    public let kinds: [AgentUIWorkKind]
    public let capabilities: [AgentUIWorkCapability]
    public let setupActions: [AgentUISetupAction]
    public let onSelect: (String) -> Void
    public let onSetup: (AgentUIProvider) -> Void
    public let onSettings: () -> Void
    public let onClose: () -> Void
    public let accessibilityIdentifier: String

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var infoCapability: AgentUIWorkCapability?
    @State private var selectedMode: AgentUIWorkKind = .text

    public init(
        status: AgentUIStatus,
        target: AgentUIWorkTarget,
        capabilities: [AgentUIWorkCapability],
        onSelect: @escaping (String) -> Void,
        onSettings: @escaping () -> Void,
        onClose: @escaping () -> Void,
        setupActions: [AgentUISetupAction] = [],
        onSetup: @escaping (AgentUIProvider) -> Void = { _ in },
        accessibilityIdentifier: String = "nativeAgent.work",
        kinds: [AgentUIWorkKind] = [.text, .image]
    ) {
        self.kinds = kinds
        self._selectedMode = State(initialValue: kinds.first ?? .text)
        self.status = status
        self.target = target
        self.capabilities = capabilities
        self.setupActions = setupActions
        self.onSelect = onSelect
        self.onSetup = onSetup
        self.onSettings = onSettings
        self.onClose = onClose
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: style.sectionSpacing) {
                header

                if !setupActions.isEmpty {
                    setupPrompt
                }

                if availableCapabilities.isEmpty {
                    emptyWorkState
                } else {
                    Text("할 수 있는 작업")
                        .font(style.headline.weight(.semibold))
                        .foregroundStyle(style.foreground)
                        .padding(.top, 2)

                    LazyVGrid(columns: capabilityColumns, spacing: 12) {
                        ForEach(availableCapabilities) { capability in
                            capabilityTile(capability)
                        }
                    }
                }
            }
            .padding(.horizontal, style.pageInset)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: style.maximumWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier(accessibilityIdentifier)
        .alert(item: $infoCapability) { capability in
            Alert(
                title: Text(capability.title),
                message: Text(capability.details.isEmpty ? (capability.reason ?? "") : capability.details),
                dismissButton: .default(Text("확인"))
            )
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(status.providers) { item in
                AgentUIProviderButton(provider: item.provider, status: status,
                                    accessibilityIdentifier: accessibilityIdentifier,
                                    action: { providerTapped(item.provider) })
            }

            Spacer(minLength: 4)

            modeSegment
                .frame(minWidth: 108, maxWidth: 140)

            Spacer(minLength: 4)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(style.body.weight(.bold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("AI 작업 닫기")
            .accessibilityIdentifier("\(accessibilityIdentifier).close")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(accessibilityIdentifier).title")
    }

    private var modeSegment: some View {
        HStack(spacing: 4) {
            ForEach(kinds) { mode in
                Button {
                    withAnimation(style.selectionAnimation) {
                        selectedMode = mode
                    }
                } label: {
                    Text(mode.title)
                        .font(style.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(
                            selectedMode == mode ? style.foreground.opacity(0.12) : .clear,
                            in: Capsule()
                        )
                        .foregroundStyle(selectedMode == mode ? style.foreground : style.secondaryForeground)
                }
                .buttonStyle(.plain)
                .accessibilityValue(selectedMode == mode ? "선택됨" : "")
                .accessibilityAddTraits(selectedMode == mode ? .isSelected : [])
                .accessibilityIdentifier("\(accessibilityIdentifier).mode.\(mode.id)")
            }
        }
        .padding(4)
        .background(style.surface, in: Capsule())
        .overlay { Capsule().stroke(style.rule, lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(accessibilityIdentifier).mode")
    }

    private func capabilityTile(_ capability: AgentUIWorkCapability) -> some View {
        ZStack(alignment: .topTrailing) {
            Button { onSelect(capability.id) } label: {
                VStack(alignment: .leading, spacing: 9) {
                    Image(systemName: capability.symbol)
                        .font(style.subtitle.weight(.semibold))
                        .foregroundStyle(style.foreground)
                        .frame(width: 46, height: 46)
                        .background(
                            style.foreground.opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .accessibilityHidden(true)

                    Spacer(minLength: 1)

                    Text(capability.title)
                        .font(style.headline.weight(.semibold))
                        .foregroundStyle(style.foreground)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .multilineTextAlignment(.leading)

                    Text(capability.outcomeLabel)
                        .font(style.caption.weight(.medium))
                        .foregroundStyle(style.secondaryForeground)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .multilineTextAlignment(.leading)

                    Label("시작", systemImage: "arrow.up.right")
                        .font(style.caption.weight(.semibold))
                        .foregroundStyle(style.foreground)
                }
                .frame(maxWidth: .infinity, minHeight: 164, alignment: .leading)
                .padding(14)
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(accessibilityIdentifier).\(shortID(for: capability))")
            .accessibilityHint(capability.reason ?? "")

            Button { infoCapability = capability } label: {
                Image(systemName: "info.circle")
                    .font(style.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(capability.title) 상세 정보")
            .accessibilityIdentifier("\(accessibilityIdentifier).\(shortID(for: capability)).info")
        }
        .background(
            style.surface,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(style.rule, lineWidth: 1)
        }
    }

    private var setupPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("준비할 항목")
                .font(style.headline.weight(.semibold))

            ForEach(setupActions) { setup in
                Button {
                    onSetup(setup.provider)
                } label: {
                    HStack(spacing: 10) {
                        AgentUIProviderMark(
                            provider: setup.provider,
                            color: style.statusColor(setup.state)
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(setup.title)
                                .font(style.subheadline.weight(.semibold))
                            Text(setup.actionTitle)
                                .font(style.caption)
                                .foregroundStyle(style.secondaryForeground)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right")
                            .font(style.body.weight(.semibold))
                            .foregroundStyle(style.statusColor(setup.state))
                    }
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue("\(setup.state.title). \(setup.message)")
                .accessibilityHint("이 항목을 바로 준비합니다")
                .accessibilityIdentifier("\(accessibilityIdentifier).setup.\(setup.provider.id)")
            }
        }
        .padding(14)
        .background(style.attention.opacity(0.08), in: RoundedRectangle(cornerRadius: style.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: style.cardRadius, style: .continuous)
                .stroke(style.attention.opacity(0.24), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(accessibilityIdentifier).setup")
    }

    private var capabilityColumns: [GridItem] {
        if typeSize.isAccessibilitySize { return [GridItem(.flexible())] }
        return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    private var availableCapabilities: [AgentUIWorkCapability] {
        capabilities.filter { $0.kind == selectedMode && $0.isAvailable }
    }

    private var emptyWorkState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: selectedMode.symbol)
                .font(style.subtitle.weight(.semibold))
                .foregroundStyle(style.unknown)
                .accessibilityHidden(true)
            Text("현재 \(selectedMode.title) 작업이 없어요")
                .font(style.subheadline.weight(.semibold))
            Text(emptyWorkMessage)
                .font(style.caption)
                .foregroundStyle(style.secondaryForeground)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.raisedSurface, in: RoundedRectangle(cornerRadius: style.cardRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: style.cardRadius, style: .continuous).stroke(style.rule, lineWidth: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(accessibilityIdentifier).empty")
    }

    private var emptyWorkMessage: String {
        status.needsConfiguration
            ? "AI 아이콘을 누르면 설정으로 이동해요."
            : "현재 조건에서 시작할 수 있는 작업이 없어요."
    }

    private func providerTapped(_ provider: AgentUIProvider) {
        guard connectionState(for: provider) != .ready else { return }
        onSettings()
    }

    private func connectionState(for provider: AgentUIProvider) -> AgentUIConnectionState {
        status.state(for: provider)
    }

    private func shortID(for capability: AgentUIWorkCapability) -> String {
        capability.accessibilityID
    }
}

