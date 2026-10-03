import Foundation
import KnowledgeCore

public protocol CaptureStagingRootProviding: Sendable {
    func stagingRoot() throws -> URL
}

public struct FileSystemStagingRootProvider: CaptureStagingRootProviding {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func stagingRoot() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

#if os(iOS)
public struct AppGroupStagingRootProvider: CaptureStagingRootProviding {
    public let groupIdentifier: String
    public let subdirectory: String

    public init(groupIdentifier: String, subdirectory: String = "ask-shared") {
        self.groupIdentifier = groupIdentifier
        self.subdirectory = subdirectory
    }

    public func stagingRoot() throws -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else {
            throw ASKError.validation("unable to resolve app group container for `\(groupIdentifier)`")
        }
        let root = container.appendingPathComponent(subdirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
#endif
