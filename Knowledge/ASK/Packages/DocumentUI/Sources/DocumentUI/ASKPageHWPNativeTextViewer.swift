#if canImport(SwiftUI)
import DocumentCore
import HWPDocument
import SwiftUI

public enum ASKPageHWPNativeTextViewerState: Sendable, Hashable {
    case idle
    case loading
    case loaded(ASKHWPDocument)
    case failed(String)
}

@MainActor public struct ASKPageHWPNativeTextViewer: View {
    public let documentURL: URL
    public let parser: ASKPageHWPNativeParser

    @State private var state: ASKPageHWPNativeTextViewerState = .idle
    @State private var loadGeneration = 0

    public init(documentURL: URL, parser: ASKPageHWPNativeParser = .init()) {
        self.documentURL = documentURL
        self.parser = parser
    }

    public var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                ProgressView("한글 문서를 읽는 중입니다.")
            case .failed(let message):
                VStack(alignment: .leading, spacing: 12) {
                    Text("한글 문서를 열 수 없습니다.")
                        .font(.headline)
                    Text(message)
                        .font(.body)
                        .textSelection(.enabled)
                }
                .padding()
            case .loaded(let document):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        Text(document.title)
                            .font(.title2.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(Array(document.sections.enumerated()), id: \.offset) { _, section in
                            sectionView(section)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: documentURL) { await load() }
    }

    private func sectionView(_ section: ASKHWPSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = section.title, !title.isEmpty {
                Text(title)
                    .font(.headline)
            }
            ForEach(section.paragraphs, id: \.index) { paragraph in
                Text(paragraph.plainText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        state = .loading
        do {
            let parser = self.parser
            let url = self.documentURL
            let document = try await Self.parseDocument(parser: parser, url: url)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            state = .loaded(document)
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            state = .failed(error.localizedDescription)
        }
    }

    private nonisolated static func parseDocument(parser: ASKPageHWPNativeParser, url: URL) async throws -> ASKHWPDocument {
        try parser.parse(fileURL: url)
    }
}
#endif
