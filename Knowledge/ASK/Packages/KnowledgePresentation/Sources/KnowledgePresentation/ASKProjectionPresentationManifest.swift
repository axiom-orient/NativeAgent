import Foundation
import KnowledgeRuntime
import DocumentCore
import DocumentRuntime
import PageIndex

public struct ASKProjectionPresentationManifest: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let defaultFilename = "askproduct.presentation.json"

    public let version: Int
    public let projectionSlug: String
    public let projectionTitle: String
    public let bundleName: String
    public let generatedFromHash: String
    public let generatedAt: String
    public let sourceIDs: [String]
    public let pageIndexKnowledgeID: String
    public let pageIndexBindings: [ASKPageIndexSourceBinding]
    public let unboundSourceIDs: [String]
    public let documentID: ASKPageDocumentID
    public let sourceID: ASKPageSourceID
    public let runtimeManifestPath: String
    public let documentJSONPath: String
    public let markdownPath: String

    public init(
        version: Int = ASKProjectionPresentationManifest.currentVersion,
        projectionSlug: String,
        projectionTitle: String,
        bundleName: String,
        generatedFromHash: String,
        generatedAt: String,
        sourceIDs: [String],
        pageIndexKnowledgeID: String? = nil,
        pageIndexBindings: [ASKPageIndexSourceBinding] = [],
        unboundSourceIDs: [String] = [],
        documentID: ASKPageDocumentID,
        sourceID: ASKPageSourceID,
        runtimeManifestPath: String = ASKPageRuntimeManifest.defaultFilename,
        documentJSONPath: String = "document.json",
        markdownPath: String = "document.md"
    ) {
        self.version = version
        self.projectionSlug = projectionSlug
        self.projectionTitle = projectionTitle
        self.bundleName = bundleName
        self.generatedFromHash = generatedFromHash
        self.generatedAt = generatedAt
        self.sourceIDs = sourceIDs
        self.pageIndexKnowledgeID = pageIndexKnowledgeID ?? Self.makePageIndexKnowledgeID(forProjectionSlug: projectionSlug)
        self.pageIndexBindings = pageIndexBindings
        self.unboundSourceIDs = unboundSourceIDs
        self.documentID = documentID
        self.sourceID = sourceID
        self.runtimeManifestPath = runtimeManifestPath
        self.documentJSONPath = documentJSONPath
        self.markdownPath = markdownPath
    }

    public static func makePageIndexKnowledgeID(forProjectionSlug projectionSlug: String) -> String {
        projectionURI(projectionSlug)
    }

    public func pageIndexSourceID(forASKSourceID askSourceID: String) -> SourceID? {
        let normalized = askSourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return pageIndexBindings.first(where: { $0.askSourceID == normalized })?.pageIndexSourceID
    }
}

public struct ASKProjectionPresentationPackage: Sendable {
    public let projection: ProjectionDocument
    public let manifest: ASKProjectionPresentationManifest
    public let bundleRootURL: URL

    public init(
        projection: ProjectionDocument,
        manifest: ASKProjectionPresentationManifest,
        bundleRootURL: URL
    ) {
        self.projection = projection
        self.manifest = manifest
        self.bundleRootURL = bundleRootURL
    }

    public var location: ASKPageDocumentLocation {
        ASKPageDocumentLocation(rootURL: bundleRootURL)
    }
}
