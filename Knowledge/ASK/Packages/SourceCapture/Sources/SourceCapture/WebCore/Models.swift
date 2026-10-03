import Foundation
import KnowledgeCore

public struct WebCaptureBundle: Sendable, Equatable {
    public var manifest: CollectedCaptureManifest
    public var collectedSource: CollectedSource
    public var rawBytes: Data
    public var curatedNoteMD: String
    public var transportPayload: ASKFields

    public init(
        manifest: CollectedCaptureManifest,
        collectedSource: CollectedSource,
        rawBytes: Data,
        curatedNoteMD: String,
        transportPayload: ASKFields = [:]
    ) {
        self.manifest = manifest
        self.collectedSource = collectedSource
        self.rawBytes = rawBytes
        self.curatedNoteMD = curatedNoteMD
        self.transportPayload = transportPayload
    }
}

public struct BrowserExportPayload: Codable, Sendable, Equatable {
    public var url: String?
    public var canonicalURL: String?
    public var finalURL: String?
    public var title: String?
    public var html: String?
    public var text: String?

    public init(url: String? = nil, canonicalURL: String? = nil, finalURL: String? = nil, title: String? = nil, html: String? = nil, text: String? = nil) {
        self.url = url
        self.canonicalURL = canonicalURL
        self.finalURL = finalURL
        self.title = title
        self.html = html
        self.text = text
    }
}

public struct ExtractionFragment: Sendable, Equatable {
    public var ordinal: Int
    public var text: String
    public var heading: String
    public var locator: ASKFields
    public var fingerprint: String

    public init(ordinal: Int, text: String, heading: String, locator: ASKFields, fingerprint: String) {
        self.ordinal = ordinal
        self.text = text
        self.heading = heading
        self.locator = locator
        self.fingerprint = fingerprint
    }
}

public struct ExtractionResult: Sendable, Equatable {
    public var title: String
    public var canonicalURL: String?
    public var language: String?
    public var description: String?
    public var publishedAt: String?
    public var markdown: String
    public var fragments: [ExtractionFragment]
    public var siteName: String?

    public init(
        title: String,
        canonicalURL: String?,
        language: String?,
        description: String?,
        publishedAt: String?,
        markdown: String,
        fragments: [ExtractionFragment],
        siteName: String?
    ) {
        self.title = title
        self.canonicalURL = canonicalURL
        self.language = language
        self.description = description
        self.publishedAt = publishedAt
        self.markdown = markdown
        self.fragments = fragments
        self.siteName = siteName
    }
}

public struct FetchedResponse: Sendable, Equatable {
    public var originalURL: String
    public var finalURL: String
    public var statusCode: Int
    public var contentType: String?
    public var html: String

    public init(originalURL: String, finalURL: String, statusCode: Int, contentType: String?, html: String) {
        self.originalURL = originalURL
        self.finalURL = finalURL
        self.statusCode = statusCode
        self.contentType = contentType
        self.html = html
    }
}
