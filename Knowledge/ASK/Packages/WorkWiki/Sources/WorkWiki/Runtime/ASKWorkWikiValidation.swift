import Foundation
import KnowledgeCore

func requireWorkWikiPatchSafeID(_ field: String, _ value: String) throws {
    try ASKValidation.requireNonEmpty(field, value)
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.:")
    guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
        throw ASKError.validation("field `\(field)` must be path-safe")
    }
}
