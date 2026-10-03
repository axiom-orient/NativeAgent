
public struct ASKPretextTypographyEngine: ASKPreparedTypographyEngine, Sendable {
    private let store: ASKPretextPreparedTextStore

    public init() {
        self.store = ASKPretextPreparedTextStore()
    }

    init(store: ASKPretextPreparedTextStore) {
        self.store = store
    }

    public func prepare(_ request: ASKTypographyRequest) async throws -> ASKPreparedTextHandle {
        try validatePointSize(request.key.font.pointSize)
        return await store.insert(request.key)
    }

    public func layoutLines(_ request: ASKLineLayoutRequest) async throws -> [ASKLaidOutLine] {
        let preparedText = try await store.preparedText(for: request.handle)
        try validatePointSize(preparedText.key.font.pointSize)
        try validateLineHeight(request.metrics.lineHeight)
        let breaker = ASKPretextLineBreaker(
            text: preparedText.key.text,
            pointSize: preparedText.key.font.pointSize,
            lineHeight: request.metrics.lineHeight
        )
        return breaker.layoutLines(maxWidth: request.width)
    }

    public func layoutCanvasRows(_ request: ASKCanvasLayoutRequest) async throws -> [ASKLaidOutRow] {
        let preparedText = try await store.preparedText(for: request.handle)
        try validatePointSize(preparedText.key.font.pointSize)
        try validateLineHeight(request.metrics.lineHeight)
        let breaker = ASKPretextLineBreaker(
            text: preparedText.key.text,
            pointSize: preparedText.key.font.pointSize,
            lineHeight: request.metrics.lineHeight
        )
        var rows: [ASKLaidOutRow] = []
        var offset = 0
        var originY = 0.0

        for row in request.rows {
            var fragments: [ASKLaidOutLine] = []
            var visualWidth = 0.0
            for fragment in row.fragments {
                guard offset < preparedText.key.text.count else { break }
                if let line = breaker.layoutSingleFragment(maxWidth: fragment.maxWidth, offset: offset, originX: fragment.originX, originY: originY) {
                    fragments.append(line)
                    visualWidth = max(visualWidth, line.originX + line.width)
                    offset = breaker.nextOffset(after: line)
                }
            }
            rows.append(.init(originY: originY, fragments: fragments, visualWidth: visualWidth))
            originY += request.metrics.lineHeight
        }

        return rows
    }

    private func validatePointSize(_ pointSize: Double) throws {
        guard pointSize.isFinite, pointSize > 0 else {
            throw ASKPretextTypographyError.invalidPointSize(pointSize)
        }
    }

    private func validateLineHeight(_ lineHeight: Double) throws {
        guard lineHeight.isFinite, lineHeight > 0 else {
            throw ASKPretextTypographyError.invalidLineHeight(lineHeight)
        }
    }
}
