import SwiftUI
import NativeAgentPresentation

// MARK: - Text task detail

/// A compact detail surface for text work. It explains the input, the local
/// processing boundary, and the result before the host starts its effect.
/// Nothing here mutates host data or assumes a particular journal model.
public struct AgentUITextWorkDetailView: View {
    @Environment(\.agentUIStyle) private var style
    public let detail: AgentUITextWorkDetail
    public let isEnabled: Bool
    public let isWorking: Bool
    public let unavailableMessage: String?
    public let onStart: () -> Void
    public let onSettings: () -> Void
    public let accessibilityIdentifier: String

    public init(
        detail: AgentUITextWorkDetail,
        isEnabled: Bool = true,
        isWorking: Bool = false,
        unavailableMessage: String? = nil,
        onStart: @escaping () -> Void,
        onSettings: @escaping () -> Void = {},
        accessibilityIdentifier: String = "nativeAgent.textWork"
    ) {
        self.detail = detail
        self.isEnabled = isEnabled
        self.isWorking = isWorking
        self.unavailableMessage = unavailableMessage
        self.onStart = onStart
        self.onSettings = onSettings
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: style.sectionSpacing) {
                intro
                pipeline
                sourceCard
                resultCard

                if !isEnabled {
                    setupCard
                }

                Button {
                    if isEnabled { onStart() } else { onSettings() }
                } label: {
                    Label(primaryActionTitle, systemImage: primaryActionSymbol)
                        .font(style.headline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.borderedProminent)
                .tint(isEnabled ? style.ready : style.attention)
                .disabled(isWorking)
                .accessibilityIdentifier("\(accessibilityIdentifier).start")
            }
            .padding(.horizontal, style.pageInset)
            .padding(.top, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: style.maximumWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .navigationTitle(detail.title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: detail.symbol)
                    .font(style.title.weight(.semibold))
                    .foregroundStyle(style.ready)
                    .frame(width: 52, height: 52)
                    .background(style.ready.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(detail.processingTitle)
                        .font(style.caption.weight(.semibold))
                        .foregroundStyle(style.ready)
                    Text(detail.title)
                        .font(style.title.weight(.bold))
                        .foregroundStyle(style.foreground)
                }
            }

            Text(detail.summary)
                .font(style.body)
                .foregroundStyle(style.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(accessibilityIdentifier).intro")
    }

    private var pipeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("작업 흐름")
                .font(style.headline.weight(.semibold))
                .padding(.bottom, 12)

            stepRow(
                index: 1,
                title: "입력",
                subtitle: detail.sourceTitle,
                symbol: "doc.text",
                state: .complete
            )
            connector
            stepRow(
                index: 2,
                title: detail.processingTitle,
                subtitle: isWorking ? "작업 중" : "시작 버튼을 누르면 실행",
                symbol: detail.processingSymbol,
                state: isWorking ? .active : .next
            )
            connector
            stepRow(
                index: 3,
                title: "결과 확인",
                subtitle: detail.resultTitle,
                symbol: "checkmark.circle",
                state: .next
            )
        }
        .padding(16)
        .background(style.raisedSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(style.rule, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(accessibilityIdentifier).pipeline")
    }

    private var sourceCard: some View {
        detailCard(
            title: "입력",
            symbol: "doc.text",
            headline: detail.sourceTitle,
            message: detail.sourceDescription,
            identifier: "\(accessibilityIdentifier).source"
        )
    }

    private var resultCard: some View {
        detailCard(
            title: "결과",
            symbol: "checkmark.circle",
            headline: detail.resultTitle,
            message: detail.resultDescription,
            identifier: "\(accessibilityIdentifier).result"
        )
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("AI를 준비해 주세요", systemImage: "gearshape")
                .font(style.headline.weight(.semibold))
                .foregroundStyle(style.attention)
            Text(unavailableMessage ?? "AI 설정에서 모델을 다운로드하면 이 작업을 사용할 수 있어요.")
                .font(style.body)
                .foregroundStyle(style.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
            Button("AI 설정 열기", action: onSettings)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("\(accessibilityIdentifier).settings")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.attention.opacity(0.08), in: RoundedRectangle(cornerRadius: style.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: style.cardRadius, style: .continuous)
                .stroke(style.attention.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(accessibilityIdentifier).setup")
    }

    private func detailCard(
        title: String,
        symbol: String,
        headline: String,
        message: String,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(style.caption.weight(.semibold))
                .foregroundStyle(style.secondaryForeground)
            Text(headline)
                .font(style.headline.weight(.semibold))
            Text(message)
                .font(style.body)
                .foregroundStyle(style.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.surface, in: RoundedRectangle(cornerRadius: style.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: style.cardRadius, style: .continuous)
                .stroke(style.rule, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var connector: some View {
        Rectangle()
            .fill(style.rule)
            .frame(width: 2, height: 12)
            .padding(.leading, 13)
    }

    private enum StepState: Equatable {
        case complete
        case active
        case next
    }

    private func stepRow(
        index: Int,
        title: String,
        subtitle: String,
        symbol: String,
        state: StepState
    ) -> some View {
        let color: Color = {
            switch state {
            case .complete: return style.ready
            case .active: return style.attention
            case .next: return .secondary
            }
        }()

        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.13))
                if state == .complete {
                    Image(systemName: "checkmark")
                        .font(style.caption.weight(.black))
                } else {
                    Text("\(index)")
                        .font(style.caption.weight(.bold).monospacedDigit())
                }
            }
            .foregroundStyle(color)
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(style.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(style.caption)
                    .foregroundStyle(style.secondaryForeground)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(style.body.weight(.semibold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(index)단계 \(title), \(subtitle)")
    }

    private var primaryActionTitle: String {
        if isWorking { return "작업 중" }
        return isEnabled ? detail.actionTitle : "AI 설정 열기"
    }

    private var primaryActionSymbol: String {
        if isWorking { return "hourglass" }
        return isEnabled ? "arrow.right.circle.fill" : "gearshape"
    }
}

