import Foundation

package struct ASKWorkWikiIndexedDocument: Equatable, Sendable {
    package var relativePath: String
    package var category: ASKWorkWikiKnowledgeCategory
    package var title: String
    package var body: String
}

package enum ASKWorkWikiKnowledgeIndex {
    private static let supportedExtensions: Set<String> = ["md", "mdx", "aiin", "txt"]

    package static func load(projectRoot: URL) throws -> [ASKWorkWikiIndexedDocument] {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        var documents: [ASKWorkWikiIndexedDocument] = []

        for category in ASKWorkWikiKnowledgeCategory.allCases {
            let directory = root.appendingPathComponent(relativeDirectory(for: category), isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            documents += try enumerateDocuments(in: directory, projectRoot: root, category: category)
        }

        return documents.sorted { lhs, rhs in
            lhs.relativePath < rhs.relativePath
        }
    }

    package static func counts(for documents: [ASKWorkWikiIndexedDocument]) -> ASKWorkWikiKnowledgeCounts {
        var counts = ASKWorkWikiKnowledgeCounts()
        for document in documents {
            counts[document.category] += 1
        }
        return counts
    }

    package static func relativeDirectory(for category: ASKWorkWikiKnowledgeCategory) -> String {
        switch category {
        case .research: "wip/research"
        case .prepare: "wip/prepare"
        case .prove: "wip/prove"
        case .docs: "wiki/docs"
        case .onit: "wip/onit"
        }
    }

    private static func enumerateDocuments(in directory: URL, projectRoot: URL, category: ASKWorkWikiKnowledgeCategory) throws -> [ASKWorkWikiIndexedDocument] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var documents: [ASKWorkWikiIndexedDocument] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let ext = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }
            let body = try decodeDocumentBody(at: fileURL)
            documents.append(
                ASKWorkWikiIndexedDocument(
                    relativePath: relativePathString(fileURL: fileURL, projectRoot: projectRoot),
                    category: category,
                    title: extractTitle(path: fileURL.deletingPathExtension().lastPathComponent, body: body),
                    body: body
                )
            )
        }
        return documents
    }

    private static func relativePathString(fileURL: URL, projectRoot: URL) -> String {
        let rootPath = projectRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard filePath.hasPrefix(rootPath) else { return fileURL.lastPathComponent }
        let suffix = filePath.dropFirst(rootPath.count)
        return suffix.hasPrefix("/") ? String(suffix.dropFirst()) : String(suffix)
    }

    private static func decodeDocumentBody(at fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private static func extractTitle(path: String, body: String) -> String {
        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                return line.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return line
        }
        return path.replacingOccurrences(of: "-", with: " ")
    }
}
