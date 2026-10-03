import NativeAgentBrowser
import NativeAgentDomain
import Foundation
import Testing

@testable import NativeAgentHTML

#if canImport(WebKit)
@MainActor
@Test(.timeLimit(.minutes(1)))
func interactiveHTMLPackPresentsEvaluatesAndExportsGeneratedContent() async throws {
    let browser = BrowserSession(policy: .localOnly())
    _ = try await browser.loadHTML("<html><body>initial</body></html>")
    let initial = try await browser.observe()
    let inspector = RenderedHTMLInspector { html in
        .object([
            "declaresAction": .bool(html.contains("data-native-agent-action=\"increment\""))
        ])
    }
    let pack = try InteractiveHTMLToolPack(session: browser, inspector: inspector)
    let executors = Dictionary(uniqueKeysWithValues: pack.executors().map { ($0.definition.name, $0) })

    #expect(executors["browser.presentHTML"]?.definition.approvalPolicy == .requireApproval)
    #expect(executors["browser.evaluateJavaScript"]?.definition.approvalPolicy == .requireApproval)
    #expect(executors["browser.exportHTML"]?.definition.approvalPolicy == .requireApproval)

    let root = FileManager.default.temporaryDirectory
    let context = ToolExecutionContext(
        sessionID: "interactive-html",
        sessionDirectoryURL: root,
        sandboxRootURL: root
    )
    let present = try #require(executors["browser.presentHTML"])
    let presented = try await present.execute(
        call: ToolCall(
            id: "present",
            name: "browser.presentHTML",
            arguments: .object([
                "html": .string("""
                <!doctype html><html><head><title>Counter</title></head><body>
                <p id='score'>0</p><button data-native-agent-action='increment'>Increment</button>
                </body></html>
                """),
                "expectedPageRevision": .string(initial.pageRevision)
            ])
        ),
        context: context
    )
    let afterPresent = try presented.output.decode(BrowserObservation.self)
    #expect(afterPresent.page.title == "Counter")

    let evaluate = try #require(executors["browser.evaluateJavaScript"])
    let evaluated = try await evaluate.execute(
        call: ToolCall(
            id: "evaluate",
            name: "browser.evaluateJavaScript",
            arguments: .object([
                "source": .string("""
                const score = document.getElementById('score');
                score.textContent = String(Number(score.textContent) + payload.delta);
                return { score: Number(score.textContent), label: payload.label };
                """),
                "arguments": .object([
                    "delta": .integer(2),
                    "label": .string("agent")
                ]),
                "expectedPageRevision": .string(afterPresent.pageRevision)
            ])
        ),
        context: context
    )
    #expect(evaluated.output.objectValue?["result"] == .object([
        "score": .integer(2),
        "label": .string("agent")
    ]))
    let observationJSON = try #require(evaluated.output.objectValue?["observation"])
    let afterEvaluate = try observationJSON.decode(BrowserObservation.self)
    #expect(afterEvaluate.visibleText.contains("2"))

    await #expect(throws: BrowserError.self) {
        _ = try await evaluate.execute(
            call: ToolCall(
                id: "stale",
                name: "browser.evaluateJavaScript",
                arguments: .object([
                    "source": .string("return payload;"),
                    "expectedPageRevision": .string(afterPresent.pageRevision)
                ])
            ),
            context: context
        )
    }

    let export = try #require(executors["browser.exportHTML"])
    let exported = try await export.execute(
        call: ToolCall(
            id: "export",
            name: "browser.exportHTML",
            arguments: .object([
                "expectedPageRevision": .string(afterEvaluate.pageRevision)
            ])
        ),
        context: context
    )
    #expect(exported.artifacts.count == 1)
    #expect(exported.artifacts[0].mimeType == "text/html")
    #expect(String(decoding: exported.artifacts[0].data, as: UTF8.self).contains(">2<"))
    #expect(exported.output.objectValue?["kind"] == .string("renderedDOM"))
    #expect(exported.output.objectValue?["inspection"] == .object([
        "declaresAction": .bool(true)
    ]))
}
#endif
