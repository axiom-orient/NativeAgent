public struct ASKLineLayoutRequest: Sendable, Hashable, Codable {
    public let handle: ASKPreparedTextHandle
    public let width: Double
    public let metrics: ASKTypographyLayoutMetrics

    public init(handle: ASKPreparedTextHandle, width: Double, metrics: ASKTypographyLayoutMetrics) {
        self.handle = handle
        self.width = width
        self.metrics = metrics
    }
}

public struct ASKVariableFragment: Sendable, Hashable, Codable {
    public let originX: Double
    public let maxWidth: Double

    public init(originX: Double, maxWidth: Double) {
        self.originX = originX
        self.maxWidth = maxWidth
    }
}

public struct ASKVariableFragmentRow: Sendable, Hashable, Codable {
    public let fragments: [ASKVariableFragment]

    public init(fragments: [ASKVariableFragment]) {
        self.fragments = fragments
    }
}

public struct ASKCanvasLayoutRequest: Sendable, Hashable, Codable {
    public let handle: ASKPreparedTextHandle
    public let rows: [ASKVariableFragmentRow]
    public let metrics: ASKTypographyLayoutMetrics

    public init(
        handle: ASKPreparedTextHandle,
        rows: [ASKVariableFragmentRow],
        metrics: ASKTypographyLayoutMetrics
    ) {
        self.handle = handle
        self.rows = rows
        self.metrics = metrics
    }
}
