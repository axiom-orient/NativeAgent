import Foundation
import NativeAgentDomain

struct StoreManifestIO {
    let layout: StoreLayout
    let fileManager: FileManager

    func loadExistingManifest() throws -> StoreManifest? {
        guard fileManager.fileExists(atPath: layout.manifestURL.path) else {
            return nil
        }
        return try decodeManifest(at: layout.manifestURL)
    }

    func decodeManifest(at url: URL) throws -> StoreManifest {
        do {
            return try StoreCodecs.decode(StoreManifest.self, from: url)
        } catch {
            throw AgentError.persistenceFailure("Unable to decode store manifest: \(error.localizedDescription)")
        }
    }

    func writeManifest(_ manifest: StoreManifest) throws {
        try fileManager.createDirectory(at: layout.configDirectoryURL, withIntermediateDirectories: true)
        try StoreCodecs.write(manifest, to: layout.manifestURL)
    }
}
