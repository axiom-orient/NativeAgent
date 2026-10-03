import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentSkills
@testable import NativeAgentSkillsWeb

#if canImport(WebKit)
import WebKit
#endif

@Suite("NativeAgentSkillsWeb", .serialized)
struct NativeAgentSkillsWebTests {
    @Test
    func policyRejectsEveryEffectfulCapabilityFromLocalRunJS() {
        let requirements = SkillCapabilityRequirements(
            requiresNetwork: true,
            allowedDomains: ["example.com"],
            requiresPersistentStorage: true,
            requiresCameraOrMicrophone: true,
            requiresExternalNavigation: true,
            bridgeIntents: ["bridge.mutate"],
            hostIntents: ["host.mutate"]
        )
        let unsupported = WebKitSkillRunnerPolicy.localPure.unsupportedCapabilities(
            for: requirements,
            exposesSecret: true
        )

        #expect(Set(unsupported) == Set([
            "secret",
            "network",
            "persistent-storage",
            "camera-or-microphone",
            "external-navigation",
            "bridge-intents(bridge.mutate)",
            "host-intents(host.mutate)",
        ]))
    }

    @Test
    func policyBoundsResourceConfiguration() {
        let policy = WebKitSkillRunnerPolicy(
            timeout: .seconds(9_999),
            maxInputBytes: .max,
            maxOutputBytes: .max
        )
        #expect(policy.timeout == WebKitSkillRunnerPolicy.maximumTimeout)
        #expect(policy.maxInputBytes == WebKitSkillRunnerPolicy.maximumInputBytes)
        #expect(policy.maxOutputBytes == WebKitSkillRunnerPolicy.maximumOutputBytes)

        let minimum = WebKitSkillRunnerPolicy(
            timeout: .seconds(-1),
            maxInputBytes: 0,
            maxOutputBytes: -1
        )
        #expect(minimum.timeout == .milliseconds(1))
        #expect(minimum.maxInputBytes == 1)
        #expect(minimum.maxOutputBytes == 1)
    }

    @Test
    func unsupportedRunnerFailsExplicitlyInsteadOfReturningFallbackSuccess() async {
        let runner = UnsupportedSkillScriptRunner()
        await #expect(throws: AgentError.self) {
            try await runner.run(
                skill: sampleSkill(),
                scriptURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("index.html"),
                readAccessURL: nil,
                inputJSON: "{}",
                secret: nil,
                context: noopContext()
            )
        }
    }

    @Test
    @MainActor
    func defaultRunnerUsesWebKitOrExplicitUnsupportedSurface() async throws {
        let runner = DefaultSkillScriptRunner.make()
        #if canImport(WebKit)
        #expect(String(describing: type(of: runner)).contains("WebKitSkillRunner"))
        #else
        await #expect(throws: AgentError.self) {
            try await runner.run(
                skill: sampleSkill(),
                scriptURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("index.html"),
                readAccessURL: nil,
                inputJSON: "{}",
                secret: nil,
                context: noopContext()
            )
        }
        #endif
    }

    #if canImport(WebKit)
    private actor CancellableSuspendedOperation {
        private var continuation: CheckedContinuation<Void, any Error>?
        private var cancellationError: (any Error)?

        func run() async throws {
            if let cancellationError {
                self.cancellationError = nil
                throw cancellationError
            }
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }

        func cancel(with error: any Error) {
            guard let continuation else {
                cancellationError = error
                return
            }
            continuation.resume(throwing: error)
            self.continuation = nil
        }
    }

    @Test
    @MainActor
    func timeoutPropagatesTaskCancellation() async throws {
        let operation = CancellableSuspendedOperation()
        let task = Task {
            try await WebKitExecutor.withTimeout(
                .seconds(30),
                cancelOperation: { error in await operation.cancel(with: error) },
                operation: { try await operation.run() }
            )
        }
        await Task.yield()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test
    func readRootRejectsSymlinkEscapeBeforeWebKitLoads() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let outside = fixture.base.appendingPathComponent("outside.html")
        try Data("<html></html>".utf8).write(to: outside)
        let link = fixture.root.appendingPathComponent("linked.html")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outside
        )

        #expect(throws: WebKitSkillRunnerError.self) {
            try WebKitNavigationBox.validatedAccess(
                scriptURL: link,
                readAccessURL: fixture.root
            )
        }
    }

    @Test
    func navigationErrorsRedactPathAndQueryDetails() {
        let remote = URL(string: "https://example.com/private?token=secret")!
        #expect(WebKitNavigationBox.redactedDestination(remote) == "https://example.com")
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("private/user/secret/index.html")
        #expect(WebKitNavigationBox.redactedDestination(local) == "index.html")
    }

    @Test
    @MainActor
    func rejectsOversizedInputBeforeCreatingWebView() async throws {
        let runner = WebKitSkillRunner(
            policy: WebKitSkillRunnerPolicy(maxInputBytes: 4)
        )
        await #expect(throws: WebKitSkillRunnerError.self) {
            try await runner.run(
                skill: sampleSkill(),
                scriptURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("does/not/need/to/exist.html"),
                readAccessURL: nil,
                inputJSON: "12345",
                secret: nil,
                context: noopContext()
            )
        }
    }

    @Test
    @MainActor
    func configurationUsesNonPersistentWebsiteDataAndBoundNavigation() async throws {
        let configuration = try await WebKitExecutor.makeConfiguration()
        #expect(configuration.websiteDataStore.isPersistent == false)
        #expect(configuration.limitsNavigationsToAppBoundDomains)
    }

    #if !os(iOS)
    @Test
    @MainActor
    func runsLocalPureHTMLWithInjectedJSON() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let scriptURL = try writeHTML(
            """
            window.nativeAgentRun = async function(data) {
              const input = JSON.parse(data);
              return JSON.stringify({ result: input.value + ":ok" });
            };
            """,
            in: fixture.root
        )
        let response = try await WebKitSkillRunner().run(
            skill: sampleSkill(),
            scriptURL: scriptURL,
            readAccessURL: fixture.root,
            inputJSON: #"{"value":"hello"}"#,
            secret: nil,
            context: noopContext()
        )
        #expect(response.result == "hello:ok")
    }

    @Test
    @MainActor
    func networkAPIsAreBlockedInsideThePage() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let scriptURL = try writeHTML(
            """
            window.nativeAgentRun = async function() {
              let blocked = false;
              try { await fetch('https://example.com/private'); }
              catch (_) { blocked = true; }
              return JSON.stringify({ result: blocked ? 'blocked' : 'unblocked' });
            };
            """,
            in: fixture.root
        )
        let response = try await WebKitSkillRunner().run(
            skill: sampleSkill(),
            scriptURL: scriptURL,
            readAccessURL: fixture.root,
            inputJSON: "{}",
            secret: nil,
            context: noopContext()
        )
        #expect(response.result == "blocked")
    }

    @Test
    @MainActor
    func rejectsSecretBeforeScriptExecution() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let scriptURL = try writeHTML(
            """
            window.nativeAgentRun = async function() {
              return JSON.stringify({ result: 'must-not-run' });
            };
            """,
            in: fixture.root
        )
        await #expect(throws: WebKitSkillRunnerError.self) {
            try await WebKitSkillRunner().run(
                skill: sampleSkill(),
                scriptURL: scriptURL,
                readAccessURL: fixture.root,
                inputJSON: "{}",
                secret: "secret",
                context: noopContext()
            )
        }
    }

    @Test
    @MainActor
    func rejectsInvalidJSONResponseWithoutEchoingPayload() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let scriptURL = try writeHTML(
            """
            window.nativeAgentRun = async function() {
              return 'not-json-private-payload';
            };
            """,
            in: fixture.root
        )
        await #expect(throws: WebKitSkillRunnerError.invalidJSON) {
            try await WebKitSkillRunner().run(
                skill: sampleSkill(),
                scriptURL: scriptURL,
                readAccessURL: fixture.root,
                inputJSON: "{}",
                secret: nil,
                context: noopContext()
            )
        }
    }
    #endif
    #endif

    private func sampleSkill(
        capabilityRequirements: SkillCapabilityRequirements = .init()
    ) -> ManagedSkill {
        ManagedSkill(
            name: "sample-skill",
            description: "sample",
            instructions: "Use run_js.",
            builtIn: true,
            selected: true,
            requiresSecret: false,
            requiresSecretDescription: "",
            homepage: "",
            capabilityRequirements: capabilityRequirements,
            group: "built-in",
            relativePath: "built-in/sample-skill",
            excerpt: "Use run_js.",
            source: ManagedSkillSource(
                kind: .bundled,
                location: "built-in/sample-skill"
            )
        )
    }

    private func noopContext() -> ToolExecutionContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeAgent-WebKit-context", isDirectory: true)
        return ToolExecutionContext(
            sessionID: "web-kit-test",
            sessionDirectoryURL: root.appendingPathComponent("session", isDirectory: true),
            sandboxRootURL: root.appendingPathComponent("sandbox", isDirectory: true)
        )
    }

    private func makeFixture() throws -> (base: URL, root: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeAgent-WebKit-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("skill", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (base, root)
    }

    private func writeHTML(_ script: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("index.html")
        let html = "<!doctype html><html><body><script>\(script)</script></body></html>"
        try Data(html.utf8).write(to: url, options: .atomic)
        return url
    }
}
