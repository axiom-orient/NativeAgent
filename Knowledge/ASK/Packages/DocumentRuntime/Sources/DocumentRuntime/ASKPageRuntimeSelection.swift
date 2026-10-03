import DocumentCore
public struct ASKPageRuntimeSelection: Sendable, Hashable, Codable {
    public let selectedKind: ASKPageArtifactKind
    public let attemptedKinds: [ASKPageArtifactKind]
    public let selectedPath: String?

    public init(
        selectedKind: ASKPageArtifactKind,
        attemptedKinds: [ASKPageArtifactKind],
        selectedPath: String? = nil
    ) {
        self.selectedKind = selectedKind
        self.attemptedKinds = attemptedKinds
        self.selectedPath = selectedPath
    }
}
