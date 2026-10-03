import DocumentCore
public protocol ASKPageRuntimePackageLoader: Sendable {
    func loadPackage(from location: ASKPageDocumentLocation) async throws -> ASKPageRuntimePackage
}
