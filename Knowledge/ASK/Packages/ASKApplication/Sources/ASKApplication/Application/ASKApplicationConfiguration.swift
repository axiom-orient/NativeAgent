import Foundation

public struct ASKApplicationConfiguration: Equatable, Hashable, Sendable {
    public var vaultURL: URL
    public var evidenceIndexURL: URL?

    public init(vaultURL: URL, evidenceIndexURL: URL? = nil) {
        self.vaultURL = Self.directoryURL(vaultURL)
        self.evidenceIndexURL = evidenceIndexURL.map(Self.directoryURL)
    }

    private static func directoryURL(_ url: URL) -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        return URL(fileURLWithPath: resolved.path, isDirectory: true)
    }

    public init(vaultPath: String, evidenceIndexPath: String? = nil) {
        self.init(
            vaultURL: URL(fileURLWithPath: vaultPath, isDirectory: true),
            evidenceIndexURL: evidenceIndexPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
    }
}

public enum ASKApplicationError: Error, Equatable, Sendable {
    case missingEvidenceIndexPath
    case mutationInProgress(actionID: String)
    case invalidMutationTransition
}
