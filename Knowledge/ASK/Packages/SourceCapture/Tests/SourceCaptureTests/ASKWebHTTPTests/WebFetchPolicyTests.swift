import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import SourceCapture

/// Web capture loads caller-supplied URLs, so the set of reachable schemes and hosts
/// has to be an explicit policy rather than whatever `URLSession` happens to support.
struct WebFetchPolicyTests {
    @Test(arguments: [
        "file:///etc/passwd",
        "ftp://example.invalid/x",
        "data:text/html,<b>x</b>",
        "about:blank",
    ])
    func nonWebSchemesAreRejected(_ urlString: String) {
        #expect(throws: (any Error).self) {
            try WebFetchPolicy.default.authorize(urlString: urlString)
        }
    }

    @Test(arguments: [
        "http://127.0.0.1:8080/",
        "http://localhost/",
        "http://localhost./",
        "http://foo.local/",
        "http://foo.local./",
        "http://service.internal/",
        "http://169.254.169.254/latest/meta-data/",
        "http://10.0.0.5/",
        "http://172.16.0.1/",
        "http://172.31.255.254/",
        "http://192.168.1.1/",
        "http://100.64.0.1/",
        "http://0.0.0.0/",
        "http://[::1]/",
        "http://[fe80::1]/",
        "http://[fd00::1]/",
        "http://[::ffff:127.0.0.1]/",
    ])
    func privateAndLoopbackHostsAreRejected(_ urlString: String) {
        #expect(throws: (any Error).self) {
            try WebFetchPolicy.default.authorize(urlString: urlString)
        }
    }

    @Test(arguments: [
        "http://127.1/",
        "http://2130706433/",
        "http://0177.0.0.1/",
        "http://0x7f000001/",
    ])
    func nonCanonicalLoopbackLiteralsAreRejected(_ urlString: String) {
        #expect(throws: (any Error).self) {
            try WebFetchPolicy.default.authorize(urlString: urlString)
        }
    }

    @Test(arguments: [
        "https://example.com/a",
        "http://93.184.216.34/",
        "http://172.32.0.1/",
        "http://[2606:2800:220:1::]/",
    ])
    func publicHostsRemainReachable(_ urlString: String) throws {
        _ = try WebFetchPolicy.default.authorize(urlString: urlString)
    }

    @Test
    func privateHostsAreReachableOnlyWhenExplicitlyEnabled() throws {
        let policy = WebFetchPolicy(allowsPrivateHosts: true)
        _ = try policy.authorize(urlString: "http://127.0.0.1:8080/")
    }

    @Test
    func requestBuilderAppliesThePolicy() {
        #expect(throws: (any Error).self) {
            try makeWebRequest(urlString: "file:///etc/passwd", timeout: 5, userAgent: "test")
        }
    }

    @Test
    func negativeResponseLimitIsRejectedBeforeRequest() {
        let policy = WebFetchPolicy(maxResponseBytes: -1)
        #expect(throws: ASKError.validation("web capture maxResponseBytes must be non-negative")) {
            try policy.authorize(urlString: "https://example.com/")
        }
    }

    /// A permitted public URL must not be able to hand the loader a private one.
    @Test
    func redirectToAPrivateHostIsRefused() throws {
        let target = try #require(URL(string: "http://169.254.169.254/latest/meta-data/"))
        #expect(try redirectOutcome(to: target) == nil)
    }

    @Test
    func redirectToAPublicHostIsAllowed() throws {
        let target = try #require(URL(string: "https://example.org/next"))
        #expect(try redirectOutcome(to: target) == target)
    }

    /// Drives the redirect delegate once and reports the URL it agreed to follow.
    private func redirectOutcome(to target: URL) throws -> URL? {
        let start = try #require(URL(string: "https://example.com/start"))
        let response = try #require(HTTPURLResponse(
            url: start,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": target.absoluteString]
        ))
        let outcome = RedirectOutcomeBox()

        WebRedirectPolicyDelegate(policy: .default).urlSession(
            .shared,
            task: URLSession.shared.dataTask(with: start),
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: target)
        ) { request in
            outcome.record(request?.url)
        }

        return try outcome.resolved()
    }
}

/// The delegate reports through a `@Sendable` completion handler, so the observed
/// value has to cross a concurrency boundary.
private final class RedirectOutcomeBox: Sendable {
    private let state = Mutex<(called: Bool, url: URL?)>((false, nil))

    func record(_ url: URL?) {
        state.withLock { $0 = (true, url) }
    }

    func resolved() throws -> URL? {
        let value = state.withLock { $0 }
        #expect(value.called, "the redirect delegate never answered")
        return value.url
    }
}
