import Foundation
import EvidenceIndex
import PageIndex

package enum TutorJSONDirectoryStore {
    @discardableResult
    package static func save<T: Encodable>(_ value: T, to url: URL, rootURL: URL, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let data = try JSONEncoderFactory.makeEncoder(prettyPrinted: true).encode(value)
        try data.write(to: url, options: .atomic)
        return url
    }

    package static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(type, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    package static func list<T: Decodable>(_ type: T.Type, in rootURL: URL, fileManager: FileManager = .default) throws -> [T] {
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }
        let decoder = JSONDecoder()
        return try urls
            .filter { $0.pathExtension == "json" }
            .map { url in
                let data = try Data(contentsOf: url)
                return try decoder.decode(type, from: data)
            }
    }
}
