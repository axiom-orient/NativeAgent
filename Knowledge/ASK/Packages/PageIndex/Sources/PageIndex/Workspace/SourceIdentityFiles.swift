import Foundation

extension SourceIdentityFactory {
    static func makeVersion(forFileAt url: URL, fileManager: FileManager = .default) throws -> SourceVersion {
        let data = try Data(contentsOf: url)
        return try makeVersion(data: data, forFileAt: url, fileManager: fileManager)
    }

    static func makeVersion(data: Data, forFileAt url: URL, fileManager: FileManager = .default) throws -> SourceVersion {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let modifiedAt = attributes[.modificationDate] as? Date
        return SourceIdentityFactory.makeVersion(data: data, modifiedAt: modifiedAt)
    }
}
