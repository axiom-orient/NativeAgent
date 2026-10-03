import Foundation

public enum ASKTutorStoreRootPolicy {
    public static func applicationSupportRoot(subdirectory: String = "ASKTutor") throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ASKTutorError.storage("unable to resolve Application Support directory")
        }
        return try resolvedApplicationSupportRoot(
            fileManager: .default,
            baseURL: base,
            subdirectory: subdirectory
        )
    }

    public static func defaultStoreRoot(subdirectory: String = "ASKTutor") throws -> URL {
        let root = try applicationSupportRoot(subdirectory: subdirectory)
        let store = root.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        return store
    }

    static func resolvedApplicationSupportRoot(
        fileManager: FileManager,
        baseURL: URL,
        subdirectory: String
    ) throws -> URL {
        let root = baseURL.appendingPathComponent(subdirectory, isDirectory: true)
        for directory in [baseURL, root] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return root
    }
}
