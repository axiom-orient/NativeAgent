import Foundation
import Markdown

/// A source-stable, CommonMark/GFM-backed outline for document indexing.
///
/// This intentionally exposes only the section data PageIndex needs. Keeping
/// the third-party AST behind this product prevents its value types and parser
/// options from becoming part of ASK's persisted source-index format.
public struct MarkdownOutlineSection: Equatable, Sendable {
    public let title: String
    public let level: Int
    public let startLine: Int

    public init(title: String, level: Int, startLine: Int) {
        self.title = title
        self.level = level
        self.startLine = startLine
    }
}

public struct MarkdownLineRange: Equatable, Sendable {
    public let startLine: Int
    public let endLine: Int

    public init(startLine: Int, endLine: Int) {
        self.startLine = startLine
        self.endLine = endLine
    }
}

public struct MarkdownOutline: Equatable, Sendable {
    public let lineCount: Int
    public let sections: [MarkdownOutlineSection]
    public let preambleRange: MarkdownLineRange?
    public let isHeaderless: Bool

    public init(
        lineCount: Int,
        sections: [MarkdownOutlineSection],
        preambleRange: MarkdownLineRange?,
        isHeaderless: Bool
    ) {
        self.lineCount = lineCount
        self.sections = sections
        self.preambleRange = preambleRange
        self.isHeaderless = isHeaderless
    }
}

public enum MarkdownSyntaxParser {
    /// Parses a document with the pinned cmark-gfm dialect and reports only
    /// genuine document-level headings. Headings nested in a quote, list, or
    /// fenced code block are deliberately not sections of the source document.
    public static func outline(markdown: String, source: URL? = nil) -> MarkdownOutline {
        // cmark's source locations count CR and LF independently in a CRLF
        // document. Normalize line endings before both parsing and counting so
        // its 1-based locations remain valid indexes for the source lines.
        let normalizedMarkdown = normalizeLineEndings(markdown)
        let lines = normalizedMarkdown.split(separator: "\n", omittingEmptySubsequences: false)
        let lineCount = lines.count
        let document = Markdown.Document(parsing: normalizedMarkdown, source: source)
        let sections = document.children.compactMap { markup -> MarkdownOutlineSection? in
            guard let heading = markup as? Markdown.Heading,
                  let range = heading.range
            else {
                return nil
            }

            let title = heading.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            return MarkdownOutlineSection(
                title: title.isEmpty ? "(untitled section)" : title,
                level: heading.level,
                startLine: range.lowerBound.line
            )
        }

        let firstHeadingLine = sections.first?.startLine ?? (lineCount + 1)
        let preambleRange: MarkdownLineRange?
        if firstHeadingLine > 1,
           lines.prefix(firstHeadingLine - 1).contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            preambleRange = MarkdownLineRange(startLine: 1, endLine: firstHeadingLine - 1)
        } else {
            preambleRange = nil
        }

        return MarkdownOutline(
            lineCount: lineCount,
            sections: sections,
            preambleRange: preambleRange,
            isHeaderless: sections.isEmpty && normalizedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        )
    }

    private static func normalizeLineEndings(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
