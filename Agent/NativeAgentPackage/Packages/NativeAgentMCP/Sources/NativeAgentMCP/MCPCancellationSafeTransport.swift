import MCP

/// Keeps the transport's cancellation notification alive after its caller is
/// cancelled. The cleanup task is awaited; transport errors remain visible.
/// The host still owns shutdown of the underlying transport.
public struct MCPCancellationSafeTransport<Base: MCPClientTransport>: MCPClientTransport {
    private let base: Base

    public init(_ base: Base) { self.base = base }

    public var endpointIdentity: String { base.endpointIdentity }

    public func open(_ request: MCPWireRequest) async throws -> MCPClientExchange {
        let exchange = try await base.open(request)
        return MCPClientExchange(frames: exchange.frames) { reason in
            try await Task.detached {
                try await exchange.cancel(reason: reason)
            }.value
        }
    }
}

extension MCPCancellationSafeTransport: MCPClientRegistryReportingTransport
where Base: MCPClientRegistryReportingTransport {
    public var registry: MCPMethodRegistry { base.registry }
}

extension MCPCancellationSafeTransport: MCPClientToolCatalogInvalidatingTransport
where Base: MCPClientToolCatalogInvalidatingTransport {
    public func invalidateToolCatalog() async { await base.invalidateToolCatalog() }
}
