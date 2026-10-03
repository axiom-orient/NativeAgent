import DocumentCore

public struct ASKPageRuntimeManifest: Sendable, Hashable, Codable {
    public static let currentVersion = 1
    public static let defaultFilename = "askpage.runtime.json"

    public let version: Int
    public let documentJSONPath: String?
    public let markdown: ASKPageRuntimeMarkdownArtifact?
    public let scenePath: String?
    public let hybridTemplatePath: String?
    public let fullHTMLPath: String?

    public init(
        version: Int = ASKPageRuntimeManifest.currentVersion,
        documentJSONPath: String? = nil,
        markdown: ASKPageRuntimeMarkdownArtifact? = nil,
        scenePath: String? = nil,
        hybridTemplatePath: String? = nil,
        fullHTMLPath: String? = nil
    ) {
        self.version = version
        self.documentJSONPath = documentJSONPath
        self.markdown = markdown
        self.scenePath = scenePath
        self.hybridTemplatePath = hybridTemplatePath
        self.fullHTMLPath = fullHTMLPath
    }

    public func artifactReference(for kind: ASKPageArtifactKind) -> ASKPageRuntimeArtifactReference? {
        switch kind {
        case .scene:
            return nonEmptyReference(kind: kind, path: scenePath)
        case .hybridTemplate:
            return nonEmptyReference(kind: kind, path: hybridTemplatePath)
        case .fullHTML:
            return nonEmptyReference(kind: kind, path: fullHTMLPath)
        case .markdown:
            guard let markdown, !markdown.path.isEmpty else {
                return nil
            }
            return ASKPageRuntimeArtifactReference(kind: .markdown, relativePath: markdown.path)
        }
    }

    public func availableArtifacts() -> [ASKPageRuntimeArtifactReference] {
        ASKPageRuntimePlanner.deterministicArtifactOrder.compactMap(artifactReference(for:))
    }

    private func nonEmptyReference(kind: ASKPageArtifactKind, path: String?) -> ASKPageRuntimeArtifactReference? {
        guard let path, !path.isEmpty else {
            return nil
        }
        return ASKPageRuntimeArtifactReference(kind: kind, relativePath: path)
    }
}

public struct ASKPageRuntimeMarkdownArtifact: Sendable, Hashable, Codable {
    public let path: String
    public let documentID: ASKPageDocumentID
    public let sourceID: ASKPageSourceID
    public let title: String?
    public let authoritativeMarkdownPath: String?

    public init(
        path: String,
        documentID: ASKPageDocumentID,
        sourceID: ASKPageSourceID,
        title: String? = nil,
        authoritativeMarkdownPath: String? = nil
    ) {
        self.path = path
        self.documentID = documentID
        self.sourceID = sourceID
        self.title = title
        self.authoritativeMarkdownPath = authoritativeMarkdownPath
    }
}

public struct ASKPageRuntimeArtifactReference: Sendable, Hashable, Codable {
    public let kind: ASKPageArtifactKind
    public let relativePath: String

    public init(kind: ASKPageArtifactKind, relativePath: String) {
        self.kind = kind
        self.relativePath = relativePath
    }
}
