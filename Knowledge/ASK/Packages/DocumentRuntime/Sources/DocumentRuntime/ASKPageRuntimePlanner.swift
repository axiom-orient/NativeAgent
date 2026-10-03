import DocumentCore
public struct ASKPageRuntimePlanner: Sendable {
    static let deterministicArtifactOrder: [ASKPageArtifactKind] = [
        .scene,
        .hybridTemplate,
        .fullHTML,
        .markdown
    ]

    public init() {}

    public func preferredArtifactOrder() -> [ASKPageArtifactKind] {
        Self.deterministicArtifactOrder
    }

    public func select(availableKinds: [ASKPageArtifactKind]) -> ASKPageRuntimeSelection? {
        var attemptedKinds: [ASKPageArtifactKind] = []
        let available = Set(availableKinds)
        for kind in preferredArtifactOrder() {
            attemptedKinds.append(kind)
            guard available.contains(kind) else {
                continue
            }
            return ASKPageRuntimeSelection(
                selectedKind: kind,
                attemptedKinds: attemptedKinds
            )
        }
        return nil
    }

    public func selectArtifact(in manifest: ASKPageRuntimeManifest) -> ASKPageRuntimeSelection? {
        var attemptedKinds: [ASKPageArtifactKind] = []
        for kind in preferredArtifactOrder() {
            attemptedKinds.append(kind)
            guard let artifact = manifest.artifactReference(for: kind) else {
                continue
            }
            return ASKPageRuntimeSelection(
                selectedKind: artifact.kind,
                attemptedKinds: attemptedKinds,
                selectedPath: artifact.relativePath
            )
        }
        return nil
    }
}
