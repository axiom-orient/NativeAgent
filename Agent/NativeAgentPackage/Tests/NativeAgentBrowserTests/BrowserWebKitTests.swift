#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import CoreGraphics
import NativeAgentDomain
import Foundation
import Testing
import NativeAgent
import NativeAgentTestSupport

@testable import NativeAgentBrowser

#if canImport(WebKit)
private actor BrowserApprovalRecorder {
    private var names: [String] = []

    func approve(_ request: ApprovalRequest) -> ApprovalDecision {
        names.append(request.toolCall.name)
        return .approved(reason: "browser integration test")
    }

    func recordedNames() -> [String] { names }
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func agentExecutesApprovedBrowserActionAndReturnsObservationToModel() async throws {
    let browser = BrowserSession(policy: .localOnly())
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgent-Browser-Agent-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? browser.close()
        try? FileManager.default.removeItem(at: storage)
    }
    _ = try await browser.loadHTML(
        """
        <html><body>
          <p id="status">ready</p>
          <button aria-label="Continue" onclick="document.getElementById('status').textContent='clicked'">Go</button>
        </body></html>
        """
    )
    let observation = try await browser.observe()
    let button = try #require(observation.elements.first { $0.role == "button" })
    let call = ToolCall(
        id: "browser-agent-click",
        name: "browser.click",
        arguments: .object([
            "elementID": .string(button.id),
            "expectedPageRevision": .string(observation.pageRevision),
        ])
    )
    let model = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "", toolCalls: [call]),
        ModelTurn(content: "browser action observed"),
    ])
    let approvals = BrowserApprovalRecorder()
    let agent = try Agent(
        model: model,
        storage: .directory(storage),
        tools: try BrowserToolPack(session: browser).executors(),
        approval: .handler { request in await approvals.approve(request) }
    )

    let run = try await agent.run("Click Continue.", sessionID: "browser-agent-integration")

    #expect(run.status == .completed)
    #expect(await approvals.recordedNames() == ["browser.click"])
    let secondRequest = try #require(await model.recordedRequests().last)
    let toolMessage = try #require(secondRequest.messages.last { $0.role == .tool })
    #expect(toolMessage.content.contains("clicked"))
}

@Test
func browserPolicyUsesNormalizedExactOriginsAndExplicitNetworkModes() throws {
    let policy = try BrowserPolicy.constrained(
        allowedOrigins: [#require(URL(string: "https://Example.COM.:443/path?ignored=1"))]
    )
    let exact = try #require(URL(string: "https://example.com/path"))
    let explicitDefaultPort = try #require(URL(string: "https://example.com:443/other"))
    let subdomain = try #require(URL(string: "https://sub.example.com/path"))
    let insecure = try #require(URL(string: "http://example.com/path"))
    let otherPort = try #require(URL(string: "https://example.com:444/path"))
    #expect(policy.allows(exact))
    #expect(policy.allows(explicitDefaultPort))
    #expect(!policy.allows(subdomain))
    #expect(!policy.allows(insecure))
    #expect(!policy.allows(otherPort))

    let local = BrowserPolicy.localOnly()
    let localFile = FileManager.default.temporaryDirectory.appendingPathComponent("local.html")
    let remote = try #require(URL(string: "https://example.com"))
    #expect(local.allows(localFile))
    #expect(!local.allows(remote))

    let unrestricted = BrowserPolicy.unrestrictedHTTPS()
    let anyHTTPS = try #require(URL(string: "https://any.example/path"))
    let anyHTTP = try #require(URL(string: "http://any.example/path"))
    #expect(unrestricted.allows(anyHTTPS))
    #expect(!unrestricted.allows(anyHTTP))

    #expect(throws: BrowserError.self) {
        _ = try BrowserPolicy.constrained(allowedOrigins: [])
    }
    let encodedRules = try policy.contentRuleJSON
    let ruleData = try #require(encodedRules.data(using: .utf8))
    let rules = try #require(
        JSONSerialization.jsonObject(with: ruleData) as? [[String: Any]]
    )
    let filters = rules.compactMap { rule in
        (rule["trigger"] as? [String: Any])?["url-filter"] as? String
    }
    #expect(filters.contains { $0.hasSuffix(#"(?:[/?#].*)?$"#) })
    #expect(throws: BrowserError.self) {
        _ = try BrowserOrigin(url: #require(URL(string: "https://user:secret@example.com")))
    }
}

@MainActor
@Test
func browserHostIntegrationDeniesSensitiveCapabilitiesUntilTheHostOptsIn() async throws {
    let integration = BrowserHostIntegration()
    let download = BrowserDownloadRequest(
        sourceOrigin: nil,
        mimeType: "application/pdf",
        suggestedFilename: "statement.pdf",
        expectedByteCount: 42
    )
    #expect(!integration.authorizes(download))
    #expect(integration.uploads(for: BrowserUploadRequest(
        sourceOrigin: nil,
        allowsMultipleSelection: false,
        allowsDirectories: false
    )).isEmpty)
    #expect(integration.popupDecision(for: BrowserPopupRequest(
        sourceOrigin: nil,
        destinationOrigin: nil
    )) == .deny)
    #expect(!integration.authorizes(BrowserMediaCaptureRequest(
        sourceOrigin: nil,
        kind: .audio
    )))
    switch integration.authenticationDecision(for: BrowserAuthenticationRequest(
        sourceOrigin: nil,
        method: .httpBasic,
        realm: "example",
        isProxy: false
    )) {
    case .cancel: break
    default: Issue.record("The default host integration must not supply credentials.")
    }

    let limits = try BrowserLimits(maximumDownloadBytes: 1_024, maximumUploadBytes: 1_024)
    let browser = BrowserSession(policy: .localOnly(limits: limits), hostIntegration: integration)
    #expect(browser.takeCompletedDownloads().isEmpty)
}

@MainActor
@Test
func browserCloseRemovesTransientStateAndRejectsReuse() async throws {
    let browser = BrowserSession(policy: .localOnly())
    let transientDirectory = browser.transientDirectory
    let stagedDirectory = transientDirectory.appendingPathComponent("uploads", isDirectory: true)
    try FileManager.default.createDirectory(
        at: stagedDirectory,
        withIntermediateDirectories: true
    )
    try Data("staged".utf8).write(
        to: stagedDirectory.appendingPathComponent("upload.txt"),
        options: .atomic
    )

    try browser.close()
    #expect(!FileManager.default.fileExists(atPath: transientDirectory.path))
    try browser.close()

    await #expect(throws: BrowserError.sessionClosed) {
        _ = try await browser.observe()
    }
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func browserObservesAndActsThroughTypedPrivacyFilteredContract() async throws {
    let browser = BrowserSession(policy: .localOnly())
    defer { try? browser.close() }
    _ = try await browser.loadHTML(
        """
        <html style="background:#f0e0d0"><head><title>NativeAgent</title></head><body>
          <p id="status">ready</p>
          <p hidden>hidden-secret</p>
          <button aria-label="Continue" onclick="document.getElementById('status').textContent='clicked'">Go</button>
          <label>Name <input aria-label="Name" value="initial"></label>
          <label>Password <input type="password" aria-label="Password" value="secret-value"></label>
          <label>Mode <select aria-label="Mode"><option value="a">A</option><option value="b">B</option></select></label>
        </body></html>
        """
    )

    let first = try await browser.observe()
    #expect(first.page.title == "NativeAgent")
    #expect(first.page.displayURL == "about:blank")
    #expect(first.visibleText.contains("ready"))
    #expect(!first.visibleText.contains("hidden-secret"))
    #expect(!first.visibleText.contains("secret-value"))

    let button = try #require(first.elements.first { $0.role == "button" })
    let name = try #require(first.elements.first { $0.label == "Name" })
    let password = try #require(first.elements.first { $0.label == "Password" })
    let mode = try #require(first.elements.first { $0.role == "combobox" })
    #expect(password.isSensitive)
    #expect(!password.isEditable)

    let afterClick = try await browser.click(
        elementID: button.id,
        expectedPageRevision: first.pageRevision
    )
    #expect(afterClick.visibleText.contains("clicked"))

    await #expect(throws: BrowserError.self) {
        _ = try await browser.type(
            text: "stale",
            into: name.id,
            expectedPageRevision: first.pageRevision
        )
    }

    let afterType = try await browser.type(
        text: "Ada",
        into: name.id,
        expectedPageRevision: afterClick.pageRevision
    )
    let typed = try await browser.evaluateJavaScript(
        "return document.querySelector('input[aria-label=Name]').value;"
    )
    #expect(typed == .string("Ada"))

    await #expect(throws: BrowserError.self) {
        _ = try await browser.type(
            text: "must-not-write",
            into: password.id,
            expectedPageRevision: afterType.pageRevision
        )
    }

    let current = try await browser.observe()
    _ = try await browser.select(
        value: "b",
        in: mode.id,
        expectedPageRevision: current.pageRevision
    )
    let selected = try await browser.evaluateJavaScript(
        "return document.querySelector('select').value;"
    )
    #expect(selected == .string("b"))

    let snapshot = try await browser.snapshot()
    #expect(snapshot.mimeType == "image/png")
    #expect(snapshot.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    // A native callback or PNG header alone cannot prove rendered content.
    #if canImport(UIKit)
    let image = try #require(UIImage(data: snapshot.data)?.cgImage)
    #elseif canImport(AppKit)
    let image = try #require(NSBitmapImageRep(data: snapshot.data)?.cgImage)
    #endif
    let center = try #require(image.cropping(to: CGRect(
        x: image.width / 2, y: image.height / 2, width: 1, height: 1)))
    var pixel = [UInt8](repeating: 0, count: 4)
    try pixel.withUnsafeMutableBytes { buffer in
        let context = try #require(CGContext(
            data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    #expect(abs(Int(pixel[0]) - 240) < 12)
    #expect(abs(Int(pixel[1]) - 224) < 12)
    #expect(abs(Int(pixel[2]) - 208) < 12)
    #expect(pixel[3] == 255)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func constrainedBrowserPolicyCompilesForRootQueryOrigins() async throws {
    let policy = try BrowserPolicy.constrained(
        allowedOrigins: [#require(URL(string: "https://example.com"))]
    )
    let browser = BrowserSession(policy: policy)
    _ = try await browser.loadHTML(
        "<html><body>bounded</body></html>",
        baseURL: URL(string: "https://example.com?source=local")
    )
    #expect((try await browser.observe()).visibleText == "bounded")
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func browserEnforcesHTMLJavaScriptAndObservationBounds() async throws {
    let limits = try BrowserLimits(
        maximumHTMLBytes: 128,
        maximumJavaScriptSourceBytes: 32,
        maximumJavaScriptResultBytes: 1_024,
        maximumVisibleTextBytes: 5,
        maximumObservedElements: 1
    )
    let browser = BrowserSession(policy: .localOnly(limits: limits))
    _ = try await browser.loadHTML("<html><body>abcdefgh<button>A</button><button>B</button></body></html>")

    let observation = try await browser.observe()
    #expect(observation.visibleText.utf8.count <= 5)
    #expect(observation.visibleTextWasTruncated)
    #expect(observation.elements.count == 1)
    #expect(observation.omittedElementCount >= 1)

    await #expect(throws: BrowserError.self) {
        _ = try await browser.evaluateJavaScript("return 'this source is deliberately longer than thirty-two bytes';")
    }

    let resultLimits = try BrowserLimits(
        maximumJavaScriptSourceBytes: 32,
        maximumJavaScriptResultBytes: 32
    )
    let resultBrowser = BrowserSession(policy: .localOnly(limits: resultLimits))
    _ = try await resultBrowser.loadHTML("<html><body>ready</body></html>")
    await #expect(throws: BrowserError.self) {
        _ = try await resultBrowser.evaluateJavaScript("return 'x'.repeat(100);")
    }
    await #expect(throws: BrowserError.self) {
        _ = try await browser.loadHTML(String(repeating: "x", count: 129))
    }
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func browserRequiresReplacementAfterInterruptedJavaScript() async throws {
    let limits = try BrowserLimits(operationTimeout: .milliseconds(100))
    let browser = BrowserSession(policy: .localOnly(limits: limits))
    _ = try await browser.loadHTML("<html><body>ready</body></html>")

    await #expect(throws: BrowserError.self) {
        _ = try await browser.evaluateJavaScript(
            "await new Promise(resolve => setTimeout(resolve, 5_000)); return 'late';"
        )
    }
    #expect(browser.requiresReplacement)
    await #expect(throws: BrowserError.self) {
        _ = try await browser.observe()
    }

    let replacement = browser.makeReplacementSession()
    _ = try await replacement.loadHTML("<html><body>recovered</body></html>")
    #expect((try await replacement.observe()).visibleText == "recovered")
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func browserToolPackExposesTypedActionsWithoutArbitraryJavaScript() async throws {
    let browser = BrowserSession(policy: .localOnly())
    _ = try await browser.loadHTML(
        "<html><body><label>Name <input aria-label='Name'></label></body></html>"
    )
    let pack = try BrowserToolPack(session: browser)
    let executors = Dictionary(uniqueKeysWithValues: pack.executors().map { ($0.definition.name, $0) })

    #expect(executors["browser.observe"]?.definition.approvalPolicy == .automatic)
    #expect(executors["browser.observe"]?.definition.isReadOnly == true)
    #expect(executors["browser.type"]?.definition.approvalPolicy == .requireApproval)
    #expect(executors["browser.type"]?.definition.isReadOnly == false)
    #expect(executors["browser.evaluateJavaScript"] == nil)

    let root = FileManager.default.temporaryDirectory
    let context = ToolExecutionContext(
        sessionID: "runtime-session",
        sessionDirectoryURL: root,
        sandboxRootURL: root
    )
    let observe = try #require(executors["browser.observe"])
    let observedResult = try await observe.execute(
        call: ToolCall(id: "observe", name: "browser.observe", arguments: .object([:])),
        context: context
    )
    let observation = try observedResult.output.decode(BrowserObservation.self)
    let field = try #require(observation.elements.first { $0.label == "Name" })

    let navigate = try #require(executors["browser.navigate"])
    await #expect(throws: AgentError.self) {
        _ = try await navigate.execute(
            call: ToolCall(
                id: "local-file",
                name: "browser.navigate",
                arguments: .object(["url": .string("file:///etc/passwd")])
            ),
            context: context
        )
    }

    let type = try #require(executors["browser.type"])
    let typedResult = try await type.execute(
        call: ToolCall(
            id: "type",
            name: "browser.type",
            arguments: .object([
                "elementID": .string(field.id),
                "text": .string("Grace"),
                "expectedPageRevision": .string(observation.pageRevision)
            ])
        ),
        context: context
    )
    let afterType = try typedResult.output.decode(BrowserObservation.self)
    #expect(afterType.pageRevision != observation.pageRevision)
    #expect(typedResult.metadata["browserSessionID"] == .string(browser.sessionID))
}
#endif
