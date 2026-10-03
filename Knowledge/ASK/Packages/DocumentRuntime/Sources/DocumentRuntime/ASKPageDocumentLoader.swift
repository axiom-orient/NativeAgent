public import Foundation
import DocumentCore

public struct ASKPageDocumentLocation: Sendable, Hashable, Codable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }
}

public protocol ASKPageDocumentLoader: Sendable {
    func loadDocument(from location: ASKPageDocumentLocation) async throws -> ASKPageDocument
}
