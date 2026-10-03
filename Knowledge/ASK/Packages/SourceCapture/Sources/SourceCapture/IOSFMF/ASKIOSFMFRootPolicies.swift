import Foundation
import KnowledgeCore

public enum ASKIOSFMFRootPolicy {
    public static func applicationSupportRoot(subdirectory: String = "ASK") throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ASKError.validation("unable to resolve Application Support directory")
        }
        let root = base.appendingPathComponent(subdirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

extension ASKIOSFMFConfiguration {
    public static func applicationSupport(subdirectory: String = "ASK") throws -> ASKIOSFMFConfiguration {
        try ASKIOSFMFConfiguration(rootURL: ASKIOSFMFRootPolicy.applicationSupportRoot(subdirectory: subdirectory))
    }
}
