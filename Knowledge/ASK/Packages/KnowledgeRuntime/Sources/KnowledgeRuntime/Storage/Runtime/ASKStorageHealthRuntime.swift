import Foundation

public actor ASKStorageHealthRuntime {
    private let canonical: any ASKCanonicalGenerationReading
    private let derivedIndexes: [any ASKDerivedGenerationReading]

    public init(
        canonical: any ASKCanonicalGenerationReading,
        derivedIndexes: [any ASKDerivedGenerationReading]
    ) {
        self.canonical = canonical
        self.derivedIndexes = derivedIndexes
    }

    public func healthReport() async throws -> ASKStorageHealthReport {
        let context = try await generationContext()
        let canonicalGeneration = context.canonicalGeneration
        let freshness = try await withThrowingTaskGroup(of: ASKDerivedFreshness.self) { group in
            for index in derivedIndexes {
                group.addTask(operation: { [self] in
                    let component = await index.component
                    do {
                        let actual = try await self.currentGeneration(for: index, context: context)
                        return ASKDerivedFreshness(
                            component: component,
                            state: self.state(expected: canonicalGeneration, actual: actual, component: component),
                            expectedGeneration: canonicalGeneration.value,
                            actualGeneration: actual?.value
                        )
                    } catch {
                        return ASKDerivedFreshness(
                            component: component,
                            state: .corrupt,
                            expectedGeneration: canonicalGeneration.value,
                            actualGeneration: nil
                        )
                    }
                })
            }
            var values: [ASKDerivedFreshness] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        return ASKStorageHealthReport(
            canonicalGeneration: canonicalGeneration,
            derivedFreshness: freshness
        )
    }

    public func rebuild(_ scope: ASKStorageRebuildScope) async throws -> ASKStorageRebuildSummary {
        let context = try await generationContext()
        let canonicalGeneration = context.canonicalGeneration
        let targets = await derivedIndexesForScope(scope)
        let results = try await canRebuildInParallel(targets)
            ? rebuildInParallel(targets, context: context, canonicalGeneration: canonicalGeneration)
            : rebuildSerially(targets, context: context, canonicalGeneration: canonicalGeneration)

        return ASKStorageRebuildSummary(
            scope: scope,
            canonicalGeneration: canonicalGeneration,
            results: results
        )
    }

    private func derivedIndexesForScope(_ scope: ASKStorageRebuildScope) async -> [any ASKDerivedGenerationReading] {
        switch scope {
        case .search:
            return await derivedIndexes.matching(.search)
        case .evidence:
            return await derivedIndexes.matching(.evidence)
        case .allDerived, .full:
            return derivedIndexes
        }
    }

    private func canRebuildInParallel(_ targets: [any ASKDerivedGenerationReading]) async -> Bool {
        guard targets.count > 1 else { return false }
        var seen: Set<ASKDerivedComponent> = []
        for target in targets {
            let component = await target.component
            guard component == .search || component == .evidence else { return false }
            guard seen.insert(component).inserted else { return false }
        }
        return seen.count > 1
    }

    private func rebuildSerially(
        _ targets: [any ASKDerivedGenerationReading],
        context: ASKStorageGenerationContext,
        canonicalGeneration: ASKStorageGeneration
    ) async throws -> [ASKStorageRebuildResult] {
        var results: [ASKStorageRebuildResult] = []
        for index in targets {
            results.append(try await rebuildResult(for: index, context: context, canonicalGeneration: canonicalGeneration))
        }
        return results
    }

    private nonisolated func rebuildInParallel(
        _ targets: [any ASKDerivedGenerationReading],
        context: ASKStorageGenerationContext,
        canonicalGeneration: ASKStorageGeneration
    ) async throws -> [ASKStorageRebuildResult] {
        try await withThrowingTaskGroup(of: ASKStorageRebuildResult.self) { group in
            for index in targets {
                group.addTask(operation: { [self] in
                    try await self.rebuildResult(for: index, context: context, canonicalGeneration: canonicalGeneration)
                })
            }
            var results: [ASKStorageRebuildResult] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
    }

    private func generationContext() async throws -> ASKStorageGenerationContext {
        if let contextual = canonical as? any ASKCanonicalGenerationContextReading {
            return try await contextual.currentGenerationContext()
        }
        return ASKStorageGenerationContext(canonicalGeneration: try await canonical.currentGeneration())
    }

    private nonisolated func currentGeneration(
        for index: any ASKDerivedGenerationReading,
        context: ASKStorageGenerationContext
    ) async throws -> ASKStorageGeneration? {
        if let contextual = index as? any ASKDerivedGenerationContextReading {
            return try await contextual.currentGeneration(context: context)
        }
        return try await index.currentGeneration()
    }

    private nonisolated func rebuildResult(
        for index: any ASKDerivedGenerationReading,
        context: ASKStorageGenerationContext,
        canonicalGeneration: ASKStorageGeneration
    ) async throws -> ASKStorageRebuildResult {
        let component = await index.component
        let before = try await currentGeneration(for: index, context: context)
        let after = try await index.rebuild(to: canonicalGeneration)
        return ASKStorageRebuildResult(
            component: component,
            beforeGeneration: before?.value,
            afterGeneration: after.value,
            stateAfterRebuild: state(expected: canonicalGeneration, actual: after, component: component)
        )
    }

    private nonisolated func state(
        expected: ASKStorageGeneration,
        actual: ASKStorageGeneration?,
        component: ASKDerivedComponent
    ) -> ASKComponentState {
        guard let actual else { return .missing }
        guard actual.component == component else { return .corrupt }
        if actual.value == expected.value { return .healthy }
        if actual.value < expected.value { return .stale }
        return .corrupt
    }
}

private extension Array where Element == any ASKDerivedGenerationReading {
    func matching(_ component: ASKDerivedComponent) async -> [any ASKDerivedGenerationReading] {
        var result: [any ASKDerivedGenerationReading] = []
        for index in self {
            if await index.component == component {
                result.append(index)
            }
        }
        return result
    }
}
