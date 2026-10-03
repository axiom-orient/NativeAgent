import Foundation
import Testing
@testable @_spi(Service) import ChatGPTAccount

private let callbackRequest = "GET /auth/callback?code=fixture&state=fixture HTTP/1.1\r\nHost: localhost:1455\r\n\r\n"

@Test func callbackParserAcceptsOnlyTheSelectedEndpoint() throws {
  let redirect = try ChatGPTProtocolProfile.callbackRedirectURI(port: 1_455)
  let expected = try #require(URL(string: "http://localhost:1455/auth/callback?code=fixture&state=fixture"))
  #expect(ChatGPTCallbackRequest.parse(Data(callbackRequest.utf8), matching: redirect) == .callback(expected))
  let fallback = try ChatGPTProtocolProfile.callbackRedirectURI(port: 1_457)
  #expect(ChatGPTCallbackRequest.parse(Data(callbackRequest.utf8), matching: fallback) == .invalid)
}

@Test func callbackParserKeepsEveryTruncatedValidPrefixIncomplete() throws {
  let redirect = try ChatGPTProtocolProfile.callbackRedirectURI(port: 1_455)
  let bytes = Data(callbackRequest.utf8)
  for length in 0..<bytes.count {
    #expect(ChatGPTCallbackRequest.parse(Data(bytes.prefix(length)), matching: redirect) == .incomplete)
  }
}

@Test(arguments: [
  "POST /auth/callback HTTP/1.1\r\nHost: localhost:1455\r\n\r\n",
  "GET /other HTTP/1.1\r\nHost: localhost:1455\r\n\r\n",
  "GET /auth/%63allback HTTP/1.1\r\nHost: localhost:1455\r\n\r\n",
  "GET //attacker.invalid/auth/callback HTTP/1.1\r\nHost: localhost:1455\r\n\r\n",
  "GET /auth/callback#fragment HTTP/1.1\r\nHost: localhost:1455\r\n\r\n",
  "GET /auth/callback HTTP/1.0\r\nHost: localhost:1455\r\n\r\n",
  "GET  /auth/callback HTTP/1.1\r\nHost: localhost:1455\r\n\r\n",
  "GET /auth/callback HTTP/1.1\r\nHost: localhost:1457\r\n\r\n",
  "GET /auth/callback HTTP/1.1\r\nHost: evil.invalid:1455\r\n\r\n",
  "GET /auth/callback HTTP/1.1\r\n\r\n"
])
func callbackCompleteInvalidRequestIsRejectedImmediately(request: String) throws {
  let redirect = try ChatGPTProtocolProfile.callbackRedirectURI(port: 1_455)
  #expect(ChatGPTCallbackRequest.parse(Data(request.utf8), matching: redirect) == .invalid)
}

@Test(arguments: [
  "Content-Length: 8", "Content-Length: -1", "Content-Length: 0\r\nContent-Length: 0",
  "Transfer-Encoding: chunked", "Host: localhost:1455", "X Header: invalid",
  "X-Test : whitespace", "X-Test: bad\u{0}", "X-Test: bad\u{7f}", " folded: value"
])
func callbackBodySmugglingAndMalformedHeadersAreRejected(header: String) throws {
  let redirect = try ChatGPTProtocolProfile.callbackRedirectURI(port: 1_455)
  let request = "GET /auth/callback HTTP/1.1\r\nHost: localhost:1455\r\n\(header)\r\n\r\n"
  #expect(ChatGPTCallbackRequest.parse(Data(request.utf8), matching: redirect) == .invalid)
}

@Test func callbackZeroLengthAndCaseInsensitiveHeaderNamesRemainValid() throws {
  let redirect = try ChatGPTProtocolProfile.callbackRedirectURI(port: 1_455)
  let request = "GET /auth/callback HTTP/1.1\r\nhOsT: localhost:1455\r\nContent-Length: 0\r\nX-Test:\tvalue\r\n\r\n"
  #expect(ChatGPTCallbackRequest.parse(Data(request.utf8), matching: redirect) == .callback(redirect))
}

@Test func callbackPipelinedOrTrailingBodyIsInvalid() throws {
  let redirect = try ChatGPTProtocolProfile.callbackRedirectURI(port: 1_455)
  for suffix in ["x", callbackRequest] {
    #expect(ChatGPTCallbackRequest.parse(Data((callbackRequest + suffix).utf8), matching: redirect) == .invalid)
  }
}

@Test func callbackSizeBoundaryIncludesHeaderTerminator() throws {
  let redirect = try ChatGPTProtocolProfile.callbackRedirectURI(port: 1_455)
  let prefix = "GET /auth/callback HTTP/1.1\r\nHost: localhost:1455\r\nX-Padding: "
  let suffix = "\r\n\r\n"
  let request = prefix + String(repeating: "a",
    count: ChatGPTCallbackPolicy.maximumRequestBytes - prefix.utf8.count - suffix.utf8.count) + suffix
  #expect(ChatGPTCallbackRequest.parse(Data(request.utf8), matching: redirect) == .callback(redirect))
  #expect(ChatGPTCallbackRequest.parse(Data((request + "x").utf8), matching: redirect) == .invalid)
  #expect(ChatGPTCallbackRequest.parse(Data(repeating: 65, count: ChatGPTCallbackPolicy.maximumRequestBytes),
    matching: redirect) == .invalid)
}

@Test func callbackInvalidEncodingAndUnregisteredRedirectAreRejected() throws {
  let redirect = try ChatGPTProtocolProfile.callbackRedirectURI(port: 1_455)
  #expect(ChatGPTCallbackRequest.parse(Data([0xff]) + Data("\r\n\r\n".utf8), matching: redirect) == .invalid)
  let unregistered = try #require(URL(string: "http://localhost:9000/auth/callback"))
  #expect(ChatGPTCallbackRequest.parse(Data(callbackRequest.utf8), matching: unregistered) == .invalid)
}

@Test(arguments: [Int.min, -1, 0, 1, 2, Int.max])
func authenticationRetryPolicyIsTotalOverIntegerInputs(attempt: Int) {
  #expect(ChatGPTSubscriptionRetryPolicy.permitsAuthenticationRefresh(after: attempt) == (attempt == 0))
}
