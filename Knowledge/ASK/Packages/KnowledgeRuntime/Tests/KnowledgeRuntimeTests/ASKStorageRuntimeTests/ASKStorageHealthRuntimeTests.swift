import XCTest
import KnowledgeRuntime
@testable import KnowledgeRuntime

final class ASKStorageHealthRuntimeTests: XCTestCase {
    func testHealthReportMarksMissingAndStaleDerivedIndexes() async throws {
        let canonical = FakeCanonical(value: 3)
        let search = FakeDerived(component: .search, value: 2)
        let evidence = FakeDerived(component: .evidence, value: nil)
        let runtime = ASKStorageHealthRuntime(
            canonical: canonical,
            derivedIndexes: [search, evidence]
        )

        let report = try await runtime.healthReport()

        XCTAssertFalse(report.isHealthy)
        XCTAssertEqual(
            Set(report.derivedFreshness.map { "\($0.component.rawValue):\($0.state.rawValue)" }),
            ["search:stale", "evidence:missing"]
        )
    }

    func testRebuildUpdatesSelectedDerivedIndexToCanonicalGeneration() async throws {
        let canonical = FakeCanonical(value: 7)
        let search = FakeDerived(component: .search, value: 1)
        let evidence = FakeDerived(component: .evidence, value: 1)
        let runtime = ASKStorageHealthRuntime(
            canonical: canonical,
            derivedIndexes: [search, evidence]
        )

        let summary = try await runtime.rebuild(.search)
        let report = try await runtime.healthReport()

        XCTAssertEqual(summary.results.map(\.component), [.search])
        let searchValue = await search.currentValue()
        let evidenceValue = await evidence.currentValue()
        XCTAssertEqual(searchValue, 7)
        XCTAssertEqual(evidenceValue, 1)
        XCTAssertEqual(
            Set(report.derivedFreshness.map { "\($0.component.rawValue):\($0.state.rawValue)" }),
            ["search:healthy", "evidence:stale"]
        )
    }

    func testHealthReportUsesSharedCanonicalContextWhenAvailable() async throws {
        let canonical = ContextCountingCanonical(value: 9)
        let search = ContextAwareDerived(component: .search)
        let runtime = ASKStorageHealthRuntime(
            canonical: canonical,
            derivedIndexes: [search]
        )

        let report = try await runtime.healthReport()
        let canonicalCurrentCalls = await canonical.currentCallCount()
        let canonicalContextCalls = await canonical.contextCallCount()
        let searchCurrentCalls = await search.currentCallCount()
        let searchContextCalls = await search.contextCallCount()

        XCTAssertTrue(report.isHealthy)
        XCTAssertEqual(canonicalCurrentCalls, 0)
        XCTAssertEqual(canonicalContextCalls, 1)
        XCTAssertEqual(searchCurrentCalls, 0)
        XCTAssertEqual(searchContextCalls, 1)
    }
}

private actor FakeCanonical: ASKCanonicalGenerationReading {
    private let value: Int

    init(value: Int) {
        self.value = value
    }

    func currentGeneration() async throws -> ASKStorageGeneration {
        ASKStorageGeneration(component: .canonical, value: value, updatedAt: "2026-04-25T00:00:00Z")
    }
}

private actor FakeDerived: ASKDerivedGenerationReading {
    let component: ASKDerivedComponent
    private var value: Int?

    init(component: ASKDerivedComponent, value: Int?) {
        self.component = component
        self.value = value
    }

    func currentGeneration() async throws -> ASKStorageGeneration? {
        guard let value else { return nil }
        return ASKStorageGeneration(component: component, value: value, updatedAt: "2026-04-25T00:00:00Z")
    }

    func rebuild(to canonicalGeneration: ASKStorageGeneration) async throws -> ASKStorageGeneration {
        value = canonicalGeneration.value
        return ASKStorageGeneration(component: component, value: canonicalGeneration.value, updatedAt: canonicalGeneration.updatedAt)
    }

    func currentValue() async -> Int? {
        value
    }
}

private actor ContextCountingCanonical: ASKCanonicalGenerationContextReading {
    private let value: Int
    private var currentCalls = 0
    private var contextCalls = 0

    init(value: Int) {
        self.value = value
    }

    func currentGeneration() async throws -> ASKStorageGeneration {
        currentCalls += 1
        return generation
    }

    func currentGenerationContext() async throws -> ASKStorageGenerationContext {
        contextCalls += 1
        return ASKStorageGenerationContext(canonicalGeneration: generation)
    }

    func currentCallCount() async -> Int {
        currentCalls
    }

    func contextCallCount() async -> Int {
        contextCalls
    }

    private var generation: ASKStorageGeneration {
        ASKStorageGeneration(component: .canonical, value: value, updatedAt: "2026-04-25T00:00:00Z")
    }
}

private actor ContextAwareDerived: ASKDerivedGenerationContextReading {
    let component: ASKDerivedComponent
    private var currentCalls = 0
    private var contextCalls = 0

    init(component: ASKDerivedComponent) {
        self.component = component
    }

    func currentGeneration() async throws -> ASKStorageGeneration? {
        currentCalls += 1
        return nil
    }

    func currentGeneration(context: ASKStorageGenerationContext) async throws -> ASKStorageGeneration? {
        contextCalls += 1
        return ASKStorageGeneration(
            component: component,
            value: context.canonicalGeneration.value,
            updatedAt: context.canonicalGeneration.updatedAt
        )
    }

    func rebuild(to canonicalGeneration: ASKStorageGeneration) async throws -> ASKStorageGeneration {
        ASKStorageGeneration(component: component, value: canonicalGeneration.value, updatedAt: canonicalGeneration.updatedAt)
    }

    func currentCallCount() async -> Int {
        currentCalls
    }

    func contextCallCount() async -> Int {
        contextCalls
    }
}
