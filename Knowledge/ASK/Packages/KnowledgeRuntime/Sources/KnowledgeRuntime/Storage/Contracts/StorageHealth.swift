import Foundation

public enum ASKDerivedComponent: String, Codable, CaseIterable, Hashable, Sendable {
    case canonical
    case search
    case evidence
}

public enum ASKComponentState: String, Codable, Hashable, Sendable {
    case healthy
    case stale
    case missing
    case corrupt
}

public enum ASKStorageRebuildScope: String, Codable, CaseIterable, Hashable, Sendable {
    case search
    case evidence
    case allDerived
    case full
}

public struct ASKStorageGeneration: Codable, Hashable, Sendable {
    public let component: ASKDerivedComponent
    public let value: Int
    public let updatedAt: String

    public init(component: ASKDerivedComponent, value: Int, updatedAt: String) {
        self.component = component
        self.value = value
        self.updatedAt = updatedAt
    }
}

public struct ASKDerivedFreshness: Codable, Hashable, Sendable {
    public let component: ASKDerivedComponent
    public let state: ASKComponentState
    public let expectedGeneration: Int
    public let actualGeneration: Int?

    public init(
        component: ASKDerivedComponent,
        state: ASKComponentState,
        expectedGeneration: Int,
        actualGeneration: Int?
    ) {
        self.component = component
        self.state = state
        self.expectedGeneration = expectedGeneration
        self.actualGeneration = actualGeneration
    }
}

public struct ASKStorageHealthReport: Codable, Hashable, Sendable {
    public let canonicalGeneration: ASKStorageGeneration
    public let derivedFreshness: [ASKDerivedFreshness]

    public init(canonicalGeneration: ASKStorageGeneration, derivedFreshness: [ASKDerivedFreshness]) {
        self.canonicalGeneration = canonicalGeneration
        self.derivedFreshness = derivedFreshness.sorted { $0.component.rawValue < $1.component.rawValue }
    }

    public var isHealthy: Bool {
        derivedFreshness.allSatisfy { $0.state == .healthy }
    }
}

public struct ASKStorageRebuildResult: Codable, Hashable, Sendable {
    public let component: ASKDerivedComponent
    public let beforeGeneration: Int?
    public let afterGeneration: Int
    public let stateAfterRebuild: ASKComponentState

    public init(
        component: ASKDerivedComponent,
        beforeGeneration: Int?,
        afterGeneration: Int,
        stateAfterRebuild: ASKComponentState
    ) {
        self.component = component
        self.beforeGeneration = beforeGeneration
        self.afterGeneration = afterGeneration
        self.stateAfterRebuild = stateAfterRebuild
    }
}

public struct ASKStorageRebuildSummary: Codable, Hashable, Sendable {
    public let scope: ASKStorageRebuildScope
    public let canonicalGeneration: ASKStorageGeneration
    public let results: [ASKStorageRebuildResult]

    public init(
        scope: ASKStorageRebuildScope,
        canonicalGeneration: ASKStorageGeneration,
        results: [ASKStorageRebuildResult]
    ) {
        self.scope = scope
        self.canonicalGeneration = canonicalGeneration
        self.results = results.sorted { $0.component.rawValue < $1.component.rawValue }
    }
}

public protocol ASKCanonicalGenerationReading: Sendable {
    func currentGeneration() async throws -> ASKStorageGeneration
}

public protocol ASKDerivedGenerationReading: Sendable {
    var component: ASKDerivedComponent { get async }
    func currentGeneration() async throws -> ASKStorageGeneration?
    func rebuild(to canonicalGeneration: ASKStorageGeneration) async throws -> ASKStorageGeneration
}

package struct ASKStorageGenerationContext: Sendable {
    package let canonicalGeneration: ASKStorageGeneration
    package let searchDocCount: Int?
    package let mirrorCounts: [String: Int]?

    package init(
        canonicalGeneration: ASKStorageGeneration,
        searchDocCount: Int? = nil,
        mirrorCounts: [String: Int]? = nil
    ) {
        self.canonicalGeneration = canonicalGeneration
        self.searchDocCount = searchDocCount
        self.mirrorCounts = mirrorCounts
    }
}

package protocol ASKCanonicalGenerationContextReading: ASKCanonicalGenerationReading {
    func currentGenerationContext() async throws -> ASKStorageGenerationContext
}

package protocol ASKDerivedGenerationContextReading: ASKDerivedGenerationReading {
    func currentGeneration(context: ASKStorageGenerationContext) async throws -> ASKStorageGeneration?
}
