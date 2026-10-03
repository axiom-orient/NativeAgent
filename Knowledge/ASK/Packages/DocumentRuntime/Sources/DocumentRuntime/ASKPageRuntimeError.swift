import DocumentCore
public enum ASKPageRuntimeError: Error, Sendable {
    case missingManifest(String)
    case unsupportedManifestVersion(Int)
    case noSelectableArtifact([ASKPageArtifactKind])
    case missingCanonicalDocument
    case filePathEscapesRoot(String)
    case fileNotFound(String)
    case failedToReadText(String)
    case failedToReadData(String)
    case failedToDecodeManifest(String)
    case failedToDecodeDocument(String)
    case failedToDecodeScene(String)
}
