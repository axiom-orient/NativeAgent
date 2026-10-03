public protocol ASKPreparedTypographyEngine: Sendable {
    func prepare(_ request: ASKTypographyRequest) async throws -> ASKPreparedTextHandle
    func layoutLines(_ request: ASKLineLayoutRequest) async throws -> [ASKLaidOutLine]
    func layoutCanvasRows(_ request: ASKCanvasLayoutRequest) async throws -> [ASKLaidOutRow]
}
