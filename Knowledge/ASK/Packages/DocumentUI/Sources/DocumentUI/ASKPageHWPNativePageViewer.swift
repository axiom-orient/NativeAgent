#if canImport(SwiftUI)
import DocumentCore
import HWPDocument
import SwiftUI

public enum ASKPageHWPNativePageViewerState: Sendable, Hashable {
    case idle
    case loading
    case loaded(ASKHWPRenderedDocument)
    case failed(String)
}

@MainActor public struct ASKPageHWPNativePageViewer: View {
    public let documentURL: URL
    public let pipeline: ASKPageHWPNativeRenderPipeline
    public let fitter: ASKHWPResponsivePageFitter
    public let pageSpacing: Double

    @State private var state: ASKPageHWPNativePageViewerState = .idle
    @State private var loadGeneration = 0

    public init(
        documentURL: URL,
        pipeline: ASKPageHWPNativeRenderPipeline = .init(),
        fitter: ASKHWPResponsivePageFitter = .init(),
        pageSpacing: Double = 18
    ) {
        self.documentURL = documentURL
        self.pipeline = pipeline
        self.fitter = fitter
        self.pageSpacing = pageSpacing
    }

    public var body: some View {
        GeometryReader { geometry in
            Group {
                switch state {
                case .idle, .loading:
                    ProgressView("한글 문서를 읽고 배치하는 중입니다.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 12) {
                        Text("한글 문서를 열 수 없습니다.")
                            .font(.headline)
                        Text(message)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                case .loaded(let document):
                    ScrollView {
                        LazyVStack(spacing: normalizedPageSpacing) {
                            ForEach(document.pages, id: \.index) { page in
                                pageView(page, viewportWidth: geometry.size.width)
                            }
                        }
                        .padding(.vertical, normalizedPageSpacing)
                    }
                }
            }
            .task(id: documentURL) { await load() }
        }
    }

    private func pageView(_ page: ASKHWPRenderedPage, viewportWidth: Double) -> some View {
        let fit = fitter.fit(pageMetrics: page.metrics, viewportWidth: viewportWidth)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.background)
                .shadow(radius: 2, x: 0, y: 1)
                .frame(width: page.metrics.width, height: page.metrics.height)
            ForEach(Array(page.bodyTextFragments.enumerated()), id: \.offset) { _, fragment in
                textFragmentView(fragment)
            }
            ForEach(page.tableFragments) { table in
                tableView(table)
            }
            ForEach(page.imageFragments) { image in
                imageView(image)
            }
            ForEach(page.objectFragments) { object in
                objectView(object)
            }
        }
        .frame(width: page.metrics.width, height: page.metrics.height, alignment: .topLeading)
        .scaleEffect(fit.scale, anchor: .topLeading)
        .frame(width: fit.fittedWidth, height: fit.fittedHeight, alignment: .topLeading)
        .accessibilityLabel("Page \(page.index + 1)")
    }

    private func tableView(_ table: ASKHWPRenderedTableFragment) -> some View {
        ZStack(alignment: .topLeading) {
            // Each cell owns its border. A row fragment's outer rectangle would
            // draw through cells spanning that row and the next one.
            ForEach(table.cells) { cell in
                tableCellView(cell, tableOrigin: table.frame.origin, borderWidth: table.style.borderWidth)
            }
        }
        .frame(width: table.frame.size.width, height: table.frame.size.height, alignment: .topLeading)
        .position(x: table.frame.origin.x + table.frame.size.width / 2, y: table.frame.origin.y + table.frame.size.height / 2)
        .accessibilityLabel("Table \(table.tableID)")
    }

    private func tableCellView(_ cell: ASKHWPRenderedTableCellFragment, tableOrigin: ASKCanvasPoint, borderWidth: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(.secondary, lineWidth: max(borderWidth, 0.5))
                .frame(width: cell.frame.size.width, height: cell.frame.size.height)
            ForEach(Array(cell.textFragments.enumerated()), id: \.offset) { _, fragment in
                textFragmentView(fragment, origin: cell.frame.origin)
            }
        }
        .frame(width: cell.frame.size.width, height: cell.frame.size.height, alignment: .topLeading)
        .position(x: cell.frame.origin.x - tableOrigin.x + cell.frame.size.width / 2, y: cell.frame.origin.y - tableOrigin.y + cell.frame.size.height / 2)
    }

    private func imageView(_ image: ASKHWPRenderedImageFragment) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .background(Rectangle().fill(.thinMaterial))
            Text(image.image.altText ?? image.image.binaryPath ?? image.image.referenceID ?? "image")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(4)
                .lineLimit(2)
        }
        .frame(width: image.frame.size.width, height: image.frame.size.height)
        .position(x: image.frame.origin.x + image.frame.size.width / 2, y: image.frame.origin.y + image.frame.size.height / 2)
        .accessibilityLabel(image.image.altText ?? "Image")
    }

    private func objectView(_ object: ASKHWPRenderedObjectFragment) -> some View {
        let label = object.object.text ?? object.object.name ?? object.object.referenceID ?? object.object.kind.rawValue
        return ZStack(alignment: .topLeading) {
            Rectangle().stroke(.primary, lineWidth: 1)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(4)
                .lineLimit(2)
        }
        .frame(width: object.frame.size.width, height: object.frame.size.height)
        .position(x: object.frame.origin.x + object.frame.size.width / 2, y: object.frame.origin.y + object.frame.size.height / 2)
        .accessibilityLabel("Object \(object.object.kind.rawValue)")
    }

    private func textFragmentView(_ fragment: ASKHWPRenderedTextFragment, origin: ASKCanvasPoint = .init(x: 0, y: 0)) -> some View {
        Text(fragment.text)
            .font(.system(size: fragment.fontSize))
            .fontWeight(fragment.attributes.isBold ? .bold : .regular)
            .italic(fragment.attributes.isItalic)
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: fragment.frame.size.width, height: fragment.frame.size.height, alignment: .leading)
            .position(x: fragment.frame.origin.x - origin.x + fragment.frame.size.width / 2, y: fragment.frame.origin.y - origin.y + fragment.frame.size.height / 2)
            .textSelection(.enabled)
    }

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        state = .loading
        do {
            let pipeline = self.pipeline
            let url = self.documentURL
            let renderedDocument = try await Self.renderDocument(pipeline: pipeline, url: url)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            state = .loaded(renderedDocument)
        } catch let error as ASKHWPError {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            state = .failed(error.localizedDescription)
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            state = .failed("Unexpected native HWP rendering failure: \(error.localizedDescription)")
        }
    }

    private var normalizedPageSpacing: Double {
        pageSpacing.isFinite ? max(pageSpacing, 0) : 0
    }

    private nonisolated static func renderDocument(pipeline: ASKPageHWPNativeRenderPipeline, url: URL) async throws -> ASKHWPRenderedDocument {
        try pipeline.render(fileURL: url)
    }
}
#endif
