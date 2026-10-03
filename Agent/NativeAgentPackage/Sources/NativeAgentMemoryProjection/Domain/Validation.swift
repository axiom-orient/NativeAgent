import Foundation

func validateContent(_ content: String) throws {
    if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw AppError.validation("empty_content", "content is empty after sanitization")
    }
}
