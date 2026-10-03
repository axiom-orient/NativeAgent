import Foundation

/// Root configuration for ASK local package workflows.
public struct ASKConfiguration: Codable, Equatable, Sendable {
    /// Root workspace used when a request does not provide an override.
    public var workspaceURL: URL
    /// Optional vault root. Defaults to `workspaceURL/vault`.
    public var vaultURL: URL?
    /// Optional evidence index root. Defaults to `workspaceURL/index`.
    public var indexURL: URL?
    /// Optional product workspace root. Defaults to `workspaceURL/product`.
    public var productWorkspaceURL: URL?

    public init(
        workspaceURL: URL,
        vaultURL: URL? = nil,
        indexURL: URL? = nil,
        productWorkspaceURL: URL? = nil
    ) {
        let workspace = askCanonicalFileURL(workspaceURL)
        self.workspaceURL = workspace
        self.vaultURL = vaultURL.map(askCanonicalFileURL)
        self.indexURL = indexURL.map(askCanonicalFileURL)
        self.productWorkspaceURL = productWorkspaceURL.map(askCanonicalFileURL)
    }

    /// Vault root resolved from explicit configuration or `workspaceURL/vault`.
    public var resolvedVaultURL: URL {
        vaultURL ?? workspaceURL.appendingPathComponent("vault", isDirectory: true)
    }

    /// Evidence index root resolved from explicit configuration or `workspaceURL/index`.
    public var resolvedIndexURL: URL {
        indexURL ?? workspaceURL.appendingPathComponent("index", isDirectory: true)
    }

    /// Product workspace root resolved from explicit configuration or `workspaceURL/product`.
    public var resolvedProductWorkspaceURL: URL {
        productWorkspaceURL ?? workspaceURL.appendingPathComponent("product", isDirectory: true)
    }
}
