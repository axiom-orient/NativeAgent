import NativeAgentDomain
import Foundation

public struct BrowserOrigin: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    private static let maximumHostUTF8Bytes = 4_096

    public let scheme: String
    public let host: String
    public let port: Int?

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawScheme = components.scheme?.lowercased(),
              rawScheme == "https" || rawScheme == "http",
              components.user == nil,
              components.password == nil,
              let rawHost = components.host?.lowercased() else {
            throw BrowserError.invalidPolicy("Browser origins must be absolute HTTP(S) URLs without user information.")
        }
        let normalizedHost = rawHost.replacingOccurrences(
            of: #"\.+$"#,
            with: "",
            options: .regularExpression
        )
        guard !normalizedHost.isEmpty,
              normalizedHost.utf8.count <= Self.maximumHostUTF8Bytes else {
            throw BrowserError.invalidPolicy("Browser origin host is empty or exceeds the supported size.")
        }
        if let port = components.port {
            guard (1...65_535).contains(port) else {
                throw BrowserError.invalidPolicy("Browser origin port is outside the valid range.")
            }
            self.port = (rawScheme == "https" && port == 443) || (rawScheme == "http" && port == 80)
                ? nil
                : port
        } else {
            self.port = nil
        }
        self.scheme = rawScheme
        self.host = normalizedHost
    }

    public var description: String {
        let renderedHost = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(renderedHost)" + (port.map { ":\($0)" } ?? "")
    }

    func matches(_ url: URL) -> Bool {
        guard let candidate = try? BrowserOrigin(url: url) else { return false }
        return candidate == self
    }
}

public enum BrowserNetworkAccess: Sendable, Equatable {
    case localOnly
    case constrained(Set<BrowserOrigin>)
    case unrestrictedHTTPS
}

public struct BrowserLimits: Sendable, Equatable {
    public let maximumHTMLBytes: Int
    public let maximumJavaScriptSourceBytes: Int
    public let maximumJavaScriptArgumentsBytes: Int
    public let maximumJavaScriptResultBytes: Int
    public let maximumSnapshotBytes: Int
    public let maximumNavigationResponseBytes: Int64
    public let maximumDownloadBytes: Int64
    public let maximumRetainedDownloadBytes: Int64
    public let maximumRetainedDownloads: Int
    public let maximumUploadBytes: Int
    public let maximumUploadFiles: Int
    public let maximumVisibleTextBytes: Int
    public let maximumObservedElements: Int
    public let maximumActionTextBytes: Int
    public let operationTimeout: Duration
    public let navigationTimeout: Duration

    public init(
        maximumHTMLBytes: Int = 4 * 1_024 * 1_024,
        maximumJavaScriptSourceBytes: Int = 256 * 1_024,
        maximumJavaScriptArgumentsBytes: Int = 256 * 1_024,
        maximumJavaScriptResultBytes: Int = 1 * 1_024 * 1_024,
        maximumSnapshotBytes: Int = 16 * 1_024 * 1_024,
        maximumNavigationResponseBytes: Int64 = 64 * 1_024 * 1_024,
        maximumDownloadBytes: Int64 = 64 * 1_024 * 1_024,
        maximumRetainedDownloadBytes: Int64 = 64 * 1_024 * 1_024,
        maximumRetainedDownloads: Int = 8,
        maximumUploadBytes: Int = 16 * 1_024 * 1_024,
        maximumUploadFiles: Int = 16,
        maximumVisibleTextBytes: Int = 256 * 1_024,
        maximumObservedElements: Int = 512,
        maximumActionTextBytes: Int = 64 * 1_024,
        operationTimeout: Duration = .seconds(15),
        navigationTimeout: Duration = .seconds(45)
    ) throws {
        guard (1...16 * 1_024 * 1_024).contains(maximumHTMLBytes),
              (1...1 * 1_024 * 1_024).contains(maximumJavaScriptSourceBytes),
              (1...1 * 1_024 * 1_024).contains(maximumJavaScriptArgumentsBytes),
              (1...8 * 1_024 * 1_024).contains(maximumJavaScriptResultBytes),
              (1...64 * 1_024 * 1_024).contains(maximumSnapshotBytes),
              (1...512 * 1_024 * 1_024).contains(maximumNavigationResponseBytes),
              (1...512 * 1_024 * 1_024).contains(maximumDownloadBytes),
              (1...512 * 1_024 * 1_024).contains(maximumRetainedDownloadBytes),
              maximumRetainedDownloadBytes >= maximumDownloadBytes,
              (1...128).contains(maximumRetainedDownloads),
              (1...128 * 1_024 * 1_024).contains(maximumUploadBytes),
              (1...128).contains(maximumUploadFiles),
              (1...2 * 1_024 * 1_024).contains(maximumVisibleTextBytes),
              (1...4_096).contains(maximumObservedElements),
              (1...1 * 1_024 * 1_024).contains(maximumActionTextBytes),
              operationTimeout > .zero,
              operationTimeout <= .seconds(120),
              navigationTimeout > .zero,
              navigationTimeout <= .seconds(300) else {
            throw BrowserError.invalidPolicy("Browser limits are outside their supported ranges.")
        }
        self.maximumHTMLBytes = maximumHTMLBytes
        self.maximumJavaScriptSourceBytes = maximumJavaScriptSourceBytes
        self.maximumJavaScriptArgumentsBytes = maximumJavaScriptArgumentsBytes
        self.maximumJavaScriptResultBytes = maximumJavaScriptResultBytes
        self.maximumSnapshotBytes = maximumSnapshotBytes
        self.maximumNavigationResponseBytes = maximumNavigationResponseBytes
        self.maximumDownloadBytes = maximumDownloadBytes
        self.maximumRetainedDownloadBytes = maximumRetainedDownloadBytes
        self.maximumRetainedDownloads = maximumRetainedDownloads
        self.maximumUploadBytes = maximumUploadBytes
        self.maximumUploadFiles = maximumUploadFiles
        self.maximumVisibleTextBytes = maximumVisibleTextBytes
        self.maximumObservedElements = maximumObservedElements
        self.maximumActionTextBytes = maximumActionTextBytes
        self.operationTimeout = operationTimeout
        self.navigationTimeout = navigationTimeout
    }

    private init(standard: Void) {
        self.maximumHTMLBytes = 4 * 1_024 * 1_024
        self.maximumJavaScriptSourceBytes = 256 * 1_024
        self.maximumJavaScriptArgumentsBytes = 256 * 1_024
        self.maximumJavaScriptResultBytes = 1 * 1_024 * 1_024
        self.maximumSnapshotBytes = 16 * 1_024 * 1_024
        self.maximumNavigationResponseBytes = 64 * 1_024 * 1_024
        self.maximumDownloadBytes = 64 * 1_024 * 1_024
        self.maximumRetainedDownloadBytes = 64 * 1_024 * 1_024
        self.maximumRetainedDownloads = 8
        self.maximumUploadBytes = 16 * 1_024 * 1_024
        self.maximumUploadFiles = 16
        self.maximumVisibleTextBytes = 256 * 1_024
        self.maximumObservedElements = 512
        self.maximumActionTextBytes = 64 * 1_024
        self.operationTimeout = .seconds(15)
        self.navigationTimeout = .seconds(45)
    }

    public static let standard = BrowserLimits(standard: ())
}

public struct BrowserPolicy: Sendable, Equatable {
    public static let maximumAllowedOrigins = 256

    public let networkAccess: BrowserNetworkAccess
    public let allowsLocalContent: Bool
    public let limits: BrowserLimits

    public init(
        networkAccess: BrowserNetworkAccess,
        allowsLocalContent: Bool,
        limits: BrowserLimits = .standard
    ) throws {
        if case let .constrained(origins) = networkAccess,
           origins.isEmpty || origins.count > Self.maximumAllowedOrigins {
            throw BrowserError.invalidPolicy(
                "A constrained browser policy needs 1...\(Self.maximumAllowedOrigins) origins."
            )
        }
        self.networkAccess = networkAccess
        self.allowsLocalContent = allowsLocalContent
        self.limits = limits
    }

    private init(
        validatedNetworkAccess networkAccess: BrowserNetworkAccess,
        allowsLocalContent: Bool,
        limits: BrowserLimits
    ) {
        self.networkAccess = networkAccess
        self.allowsLocalContent = allowsLocalContent
        self.limits = limits
    }

    public static func localOnly(
        limits: BrowserLimits = .standard
    ) -> BrowserPolicy {
        BrowserPolicy(
            validatedNetworkAccess: .localOnly,
            allowsLocalContent: true,
            limits: limits
        )
    }

    public static func constrained(
        allowedOrigins: [URL],
        allowsLocalContent: Bool = false,
        limits: BrowserLimits = .standard
    ) throws -> BrowserPolicy {
        let origins = try Set(allowedOrigins.map(BrowserOrigin.init(url:)))
        return try BrowserPolicy(
            networkAccess: .constrained(origins),
            allowsLocalContent: allowsLocalContent,
            limits: limits
        )
    }

    public static func unrestrictedHTTPS(
        allowsLocalContent: Bool = false,
        limits: BrowserLimits = .standard
    ) -> BrowserPolicy {
        BrowserPolicy(
            validatedNetworkAccess: .unrestrictedHTTPS,
            allowsLocalContent: allowsLocalContent,
            limits: limits
        )
    }

    public func allows(_ url: URL) -> Bool {
        if url.isFileURL { return allowsLocalContent }
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" { return url.absoluteString == "about:blank" }
        switch networkAccess {
        case .localOnly:
            return false
        case let .constrained(origins):
            return origins.contains { $0.matches(url) }
        case .unrestrictedHTTPS:
            return scheme == "https" && (try? BrowserOrigin(url: url)) != nil
        }
    }

    func allows(_ origin: BrowserOrigin) -> Bool {
        switch networkAccess {
        case .localOnly:
            false
        case let .constrained(origins):
            origins.contains(origin)
        case .unrestrictedHTTPS:
            origin.scheme == "https"
        }
    }

    var contentRuleJSON: String {
        get throws {
        var rules: [[String: Any]] = []
        func appendRule(filter: String, action: String) {
            rules.append([
                "trigger": [
                    "url-filter": filter,
                    "url-filter-is-case-sensitive": false
                ],
                "action": ["type": action]
            ])
        }

        switch networkAccess {
        case .localOnly:
            appendRule(filter: #"^https?://"#, action: "block")
            appendRule(filter: #"^wss?://"#, action: "block")
            appendRule(filter: #"^ftp://"#, action: "block")
        case let .constrained(origins):
            appendRule(filter: #"^https?://"#, action: "block")
            appendRule(filter: #"^wss?://"#, action: "block")
            appendRule(filter: #"^ftp://"#, action: "block")
            for origin in origins.sorted(by: { $0.description < $1.description }) {
                appendRule(filter: origin.contentRuleURLFilter, action: "ignore-previous-rules")
            }
        case .unrestrictedHTTPS:
            appendRule(filter: #"^http://"#, action: "block")
            appendRule(filter: #"^wss?://"#, action: "block")
            appendRule(filter: #"^ftp://"#, action: "block")
        }
        let data = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
        }
    }

    var contentRuleCacheKey: String {
        let identity: String
        switch networkAccess {
        case .localOnly:
            identity = "local"
        case let .constrained(origins):
            identity = "constrained\u{0}" + origins.map(\.description).sorted().joined(separator: "\u{0}")
        case .unrestrictedHTTPS:
            identity = "https"
        }
        return String(SHA256HexDigest.digest(identity).prefix(32))
    }
}

private extension BrowserOrigin {
    var contentRuleURLFilter: String {
        let escapedHost = NSRegularExpression.escapedPattern(for: host)
        let renderedHost = host.contains(":") ? #"\["# + escapedHost + #"\]"# : escapedHost
        let renderedPort: String
        if let port {
            renderedPort = ":\(port)"
        } else if scheme == "https" {
            renderedPort = "(?::443)?"
        } else {
            renderedPort = "(?::80)?"
        }
        return "^\(scheme)://\(renderedHost)\(renderedPort)(?:[/?#].*)?$"
    }
}
