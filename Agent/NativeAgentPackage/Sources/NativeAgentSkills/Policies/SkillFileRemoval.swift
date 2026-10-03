import Foundation

struct SkillFileRemoval: Sendable {
    let removeItem: @Sendable (_ url: URL, _ fileManager: FileManager) throws -> Void

    init(removeItem: @escaping @Sendable (_ url: URL, _ fileManager: FileManager) throws -> Void) {
        self.removeItem = removeItem
    }

    static let foundation = SkillFileRemoval { url, fileManager in
        try fileManager.removeItem(at: url)
    }
}
