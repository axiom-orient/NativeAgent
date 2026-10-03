import Foundation
import DocumentCore

enum ASKHWPParserSupport {
    static func sectionIndex(from path: String) -> Int {
        let fileName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
        let digits = fileName.drop { !$0.isNumber }
        return Int(digits) ?? Int.max
    }

    static func fallbackTitle(from sections: [ASKHWPSection]) -> String? {
        for paragraph in sections.flatMap(\.paragraphs) {
            if let text = paragraph.plainText.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue {
                return text
            }
        }
        return nil
    }
}
