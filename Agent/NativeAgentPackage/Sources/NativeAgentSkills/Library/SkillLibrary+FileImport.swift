import NativeAgentDomain
import Foundation

extension SkillLibrary {
    func createOrReplaceDirectory(_ url: URL) throws {
        try fileImportPolicy.createOrReplaceDirectory(url)
    }

    func copySkillDirectory(from source: URL, to destination: URL) throws {
        try fileImportPolicy.copySkillDirectory(from: source, to: destination)
    }
}
