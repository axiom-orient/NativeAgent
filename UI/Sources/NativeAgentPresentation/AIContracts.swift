import Foundation

// MARK: - AI UI boundary

/// The provider vocabulary understood by the reusable AI surfaces.
/// Host applications map their concrete providers to this type at the edge.
public struct AgentUIProvider: Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let accessibilityTitle: String
    public let symbol: String
    public let decorationSymbol: String?

    public init(id: String, title: String, accessibilityTitle: String? = nil,
                symbol: String, decorationSymbol: String? = nil) {
        self.id = id
        self.title = title
        self.accessibilityTitle = accessibilityTitle ?? title
        self.symbol = symbol
        self.decorationSymbol = decorationSymbol
    }
}

public struct AgentUIProviderStatus: Equatable, Identifiable, Sendable {
    public let provider: AgentUIProvider
    public let state: AgentUIConnectionState
    public var id: String { provider.id }
    public init(provider: AgentUIProvider, state: AgentUIConnectionState) {
        self.provider = provider
        self.state = state
    }
}

public enum AgentUIConnectionState: String, Sendable {
    case ready
    case setupRequired
    case checking
    case working
    case unavailable

    public var title: String {
        switch self {
        case .ready: return "사용 가능"
        case .setupRequired: return "설정 필요"
        case .checking: return "확인 중"
        case .working: return "작업 중"
        case .unavailable: return "확인 필요"
        }
    }
}

/// A read-only snapshot. The host owns the source of truth and refresh policy.
public struct AgentUIStatus: Equatable, Sendable {
    public let providers: [AgentUIProviderStatus]
    public let usageProvider: AgentUIProvider?
    public let usageRemainingPercent: Int?

    public init(providers: [AgentUIProviderStatus], usageProvider: AgentUIProvider? = nil,
                usageRemainingPercent: Int? = nil) {
        self.providers = providers
        self.usageProvider = usageProvider
        self.usageRemainingPercent = usageRemainingPercent.map { min(max($0, 0), 100) }
    }

    public func state(for provider: AgentUIProvider) -> AgentUIConnectionState {
        providers.first { $0.id == provider.id }?.state ?? .unavailable
    }
    public var usageState: AgentUIConnectionState {
        usageProvider.map { state(for: $0) } ?? .unavailable
    }
    public var needsConfiguration: Bool { providers.contains { $0.state != .ready } }
    public var hasActionableSetup: Bool {
        providers.contains { [.setupRequired, .unavailable].contains($0.state) }
    }
    public var usageDescription: String {
        guard usageState == .ready else { return "사용량 확인 불가" }
        guard let usageRemainingPercent else { return "사용량 확인 중" }
        return "\(usageRemainingPercent)% 남음"
    }
}

/// Work categories are independent of provider identity.
public struct AgentUIWorkKind: Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String

    public init(id: String, title: String, symbol: String) {
        self.id = id
        self.title = title
        self.symbol = symbol
    }

    public static let text = Self(id: "text", title: "텍스트", symbol: "text.alignleft")
    public static let image = Self(id: "image", title: "이미지", symbol: "photo.artframe")
}

/// A precise, inline recovery action for a provider that needs preparation.
/// The host supplies the effect; The UI renders the missing prerequisite and the
/// one action that can resolve it without leaving the work surface.
public struct AgentUISetupAction: Equatable, Identifiable, Sendable {
    public let provider: AgentUIProvider
    public let state: AgentUIConnectionState
    public let title: String
    public let message: String
    public let actionTitle: String
    public let isBusy: Bool

    public var id: String { provider.id }

    public init(
        provider: AgentUIProvider,
        state: AgentUIConnectionState,
        title: String,
        message: String,
        actionTitle: String,
        isBusy: Bool = false
    ) {
        self.provider = provider
        self.state = state
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.isBusy = isBusy
    }
}

/// Host-owned context. The UI does not know whether the target is a journal,
/// document, or another product object.
public struct AgentUIWorkTarget: Equatable, Sendable {
    public let title: String
    public let symbol: String
    public let badge: String?

    public init(title: String, symbol: String, badge: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.badge = badge
    }
}

/// A task definition with no product-specific execution logic.
public struct AgentUIWorkCapability: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let outcomeLabel: String
    public let provider: AgentUIProvider
    public let isAvailable: Bool
    public let reason: String?
    public let details: String
    public let kind: AgentUIWorkKind
    public let accessibilityID: String

    public init(
        id: String,
        title: String,
        symbol: String,
        outcomeLabel: String,
        provider: AgentUIProvider,
        isAvailable: Bool,
        reason: String? = nil,
        details: String = "",
        kind: AgentUIWorkKind = .text,
        accessibilityID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.outcomeLabel = outcomeLabel
        self.provider = provider
        self.isAvailable = isAvailable
        self.reason = reason
        self.details = details
        self.kind = kind
        self.accessibilityID = accessibilityID ?? id
    }
}

/// A host-independent description of a text task. The UI renders the task
/// pipeline, while the host remains responsible for the source record and the
/// effect that starts the task.
public struct AgentUITextWorkDetail: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let summary: String
    public let processingTitle: String
    public let processingSymbol: String
    public let sourceTitle: String
    public let sourceDescription: String
    public let resultTitle: String
    public let resultDescription: String
    public let actionTitle: String

    public init(
        id: String,
        title: String,
        symbol: String,
        summary: String,
        sourceTitle: String,
        sourceDescription: String,
        resultTitle: String,
        resultDescription: String,
        actionTitle: String,
        processingTitle: String = "AI 처리",
        processingSymbol: String = "sparkles"
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.summary = summary
        self.processingTitle = processingTitle
        self.processingSymbol = processingSymbol
        self.sourceTitle = sourceTitle
        self.sourceDescription = sourceDescription
        self.resultTitle = resultTitle
        self.resultDescription = resultDescription
        self.actionTitle = actionTitle
    }
}

