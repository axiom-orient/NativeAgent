import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KnowledgeCore

/// Outbound policy for web capture.
///
/// `URLSession` will load whatever URL it is handed — including schemes and hosts a
/// capture tool has no business reaching. The policy makes the allowed egress explicit
/// and is applied to the initial request and again to every redirect hop.
///
/// Host checks cover literal addresses and well-known local names. A hostname that
/// resolves to a private address at connect time cannot be caught here; deployments
/// that need that guarantee must also constrain egress at the network layer.
public struct WebFetchPolicy: Sendable, Equatable {
    public var allowedSchemes: Set<String>
    public var allowsPrivateHosts: Bool
    public var maxResponseBytes: Int

    public static let `default` = WebFetchPolicy()

    public init(
        allowedSchemes: Set<String> = ["http", "https"],
        allowsPrivateHosts: Bool = false,
        maxResponseBytes: Int = 10 * 1024 * 1024
    ) {
        self.allowedSchemes = Set(allowedSchemes.map { $0.lowercased() })
        self.allowsPrivateHosts = allowsPrivateHosts
        self.maxResponseBytes = maxResponseBytes
    }

    /// Validates a URL string and returns the URL that may be requested.
    public func authorize(urlString: String) throws -> URL {
        try validate()
        guard let url = URL(string: urlString) else {
            throw ASKError.validation("invalid url `\(urlString)`")
        }
        try authorize(url: url)
        return url
    }

    public func authorize(url: URL) throws {
        try validate()
        guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else {
            throw ASKError.validation(
                "scheme `\(url.scheme ?? "")` is not permitted for web capture; allowed: \(allowedSchemes.sorted().joined(separator: ", "))"
            )
        }
        guard let host = url.host, !host.isEmpty else {
            throw ASKError.validation("url `\(url.absoluteString)` has no host")
        }
        if !allowsPrivateHosts, WebHostClassification.isPrivate(host: host) {
            throw ASKError.validation("host `\(host)` is a private or loopback address and is not permitted for web capture")
        }
    }

    public func validate() throws {
        guard maxResponseBytes >= 0 else {
            throw ASKError.validation("web capture maxResponseBytes must be non-negative")
        }
    }
}

/// Classifies a URL host as private/loopback without performing name resolution.
enum WebHostClassification {
    static func isPrivate(host: String) -> Bool {
        let normalized = normalizedHost(host)
        if isLocalName(normalized) { return true }
        if isAmbiguousNumericAddressLiteral(normalized) { return true }
        if let address = IPv4Address(normalized) { return address.isPrivate }
        if let address = IPv6Address(normalized) { return address.isPrivate }
        return false
    }

    /// Strips the brackets URL hosts use for IPv6 literals and any zone identifier.
    private static func normalizedHost(_ host: String) -> String {
        var value = host.lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        if let percent = value.firstIndex(of: "%") {
            value = String(value[value.startIndex ..< percent])
        }
        while value.count > 1 && value.hasSuffix(".") {
            value.removeLast()
        }
        return value
    }

    private static func isLocalName(_ host: String) -> Bool {
        if host == "localhost" { return true }
        for suffix in [".localhost", ".local", ".internal", ".localdomain"] where host.hasSuffix(suffix) {
            return true
        }
        return false
    }

    private static func isAmbiguousNumericAddressLiteral(_ host: String) -> Bool {
        let lowercased = host.lowercased()
        if lowercased.hasPrefix("0x") { return true }
        guard lowercased.unicodeScalars.allSatisfy({ scalar in
            scalar.value == 0x2E || (0x30 ... 0x39).contains(scalar.value)
        }) else { return false }

        let parts = lowercased.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return true }
        return parts.contains { part in
            part.isEmpty || (part.count > 1 && part.first == "0") || UInt8(part) == nil
        }
    }

    struct IPv4Address {
        let octets: [UInt8]

        init?(_ value: String) {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var octets: [UInt8] = []
            for part in parts {
                guard !part.isEmpty, part.allSatisfy(\.isNumber), let octet = UInt8(part) else { return nil }
                octets.append(octet)
            }
            self.octets = octets
        }

        var isPrivate: Bool {
            switch (octets[0], octets[1]) {
            case (0, _),                                  // "this network"
                 (10, _),                                 // RFC1918
                 (127, _),                                // loopback
                 (169, 254),                              // link-local, includes cloud metadata
                 (192, 168):                              // RFC1918
                return true
            case (172, let second) where (16 ... 31).contains(second):
                return true                               // RFC1918
            case (100, let second) where (64 ... 127).contains(second):
                return true                               // RFC6598 carrier-grade NAT
            case (192, 0):
                return octets[2] == 0 || octets[2] == 2   // IETF protocol assignments, TEST-NET-1
            case (198, 18), (198, 19):
                return true                               // benchmarking
            default:
                return octets[0] >= 224                   // multicast and reserved
            }
        }
    }

    struct IPv6Address {
        let groups: [UInt16]

        init?(_ value: String) {
            guard value.contains(":") else { return nil }
            let halves = value.components(separatedBy: "::")
            guard halves.count <= 2 else { return nil }

            func parse(_ text: String) -> [UInt16]? {
                guard !text.isEmpty else { return [] }
                var result: [UInt16] = []
                let parts = text.split(separator: ":", omittingEmptySubsequences: false)
                for (offset, part) in parts.enumerated() {
                    // The last component may be a dotted quad, as in "::ffff:127.0.0.1".
                    if offset == parts.count - 1, part.contains(".") {
                        guard let embedded = IPv4Address(String(part)) else { return nil }
                        result.append(UInt16(embedded.octets[0]) << 8 | UInt16(embedded.octets[1]))
                        result.append(UInt16(embedded.octets[2]) << 8 | UInt16(embedded.octets[3]))
                        continue
                    }
                    guard !part.isEmpty, part.count <= 4, let group = UInt16(part, radix: 16) else { return nil }
                    result.append(group)
                }
                return result
            }

            guard let leading = parse(halves[0]) else { return nil }
            if halves.count == 1 {
                guard leading.count == 8 else { return nil }
                self.groups = leading
                return
            }
            guard let trailing = parse(halves[1]), leading.count + trailing.count <= 7 else { return nil }
            self.groups = leading + Array(repeating: 0, count: 8 - leading.count - trailing.count) + trailing
        }

        var isPrivate: Bool {
            if groups == [0, 0, 0, 0, 0, 0, 0, 1] { return true }          // ::1 loopback
            if groups == [0, 0, 0, 0, 0, 0, 0, 0] { return true }          // unspecified
            let first = groups[0]
            if first & 0xFE00 == 0xFC00 { return true }                    // fc00::/7 unique local
            if first & 0xFFC0 == 0xFE80 { return true }                    // fe80::/10 link-local
            if first & 0xFF00 == 0xFF00 { return true }                  // ff00::/8 multicast
            // IPv4-mapped (::ffff:a.b.c.d) inherits the IPv4 classification.
            if groups[0 ... 4] == [0, 0, 0, 0, 0], groups[5] == 0xFFFF {
                let packed = [
                    UInt8(groups[6] >> 8), UInt8(groups[6] & 0xFF),
                    UInt8(groups[7] >> 8), UInt8(groups[7] & 0xFF),
                ]
                return IPv4Address(packed.map(String.init).joined(separator: "."))?.isPrivate ?? false
            }
            return false
        }
    }
}

/// Re-applies `WebFetchPolicy` to every redirect hop.
///
/// Without this, a permitted public URL can redirect the loader straight to a private
/// address. `URLSession`'s own redirect limit still bounds the number of hops.
final class WebRedirectPolicyDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let policy: WebFetchPolicy

    init(policy: WebFetchPolicy) {
        self.policy = policy
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, (try? policy.authorize(url: url)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
