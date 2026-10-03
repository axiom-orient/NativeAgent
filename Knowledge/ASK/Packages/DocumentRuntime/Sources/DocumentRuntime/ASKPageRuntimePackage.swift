import DocumentCore

public struct ASKPageRuntimePackage: Sendable, Hashable, Codable {
    public let document: ASKPageDocument
    public let selection: ASKPageRuntimeSelection
    public let selectedArtifact: ASKPageRuntimeArtifactPayload

    public init(
        document: ASKPageDocument,
        selection: ASKPageRuntimeSelection,
        selectedArtifact: ASKPageRuntimeArtifactPayload
    ) {
        self.document = document
        self.selection = selection
        self.selectedArtifact = selectedArtifact
    }
}

public enum ASKPageRuntimeArtifactPayload: Sendable, Hashable, Codable {
    case scene(ASKCanvasPage)
    case hybridTemplate(String)
    case fullHTML(String)
    case markdown(String)
}
