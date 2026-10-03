import Testing
import DocumentCore
@testable import DocumentRuntime

@Test("Runtime manifest exposes available artifacts in deterministic runtime order")
func runtimeManifestAvailableArtifactsAreOrdered() {
    let manifest = ASKPageRuntimeManifest(
        documentJSONPath: "document.json",
        markdown: .init(
            path: "document.md",
            documentID: .init("doc-1"),
            sourceID: .init("src-1")
        ),
        scenePath: "scene.json",
        hybridTemplatePath: "hybrid-template.html",
        fullHTMLPath: "full.html"
    )

    #expect(manifest.availableArtifacts() == [
        .init(kind: .scene, relativePath: "scene.json"),
        .init(kind: .hybridTemplate, relativePath: "hybrid-template.html"),
        .init(kind: .fullHTML, relativePath: "full.html"),
        .init(kind: .markdown, relativePath: "document.md")
    ])
}

@Test("Runtime planner selects the highest-priority available artifact and records the chosen path")
func runtimePlannerSelectsHighestPriorityArtifact() {
    let planner = ASKPageRuntimePlanner()
    let manifest = ASKPageRuntimeManifest(
        documentJSONPath: "document.json",
        markdown: .init(
            path: "document.md",
            documentID: .init("doc-1"),
            sourceID: .init("src-1")
        ),
        hybridTemplatePath: "hybrid-template.html",
        fullHTMLPath: "full.html"
    )

    let selection = planner.selectArtifact(in: manifest)

    #expect(selection == .init(
        selectedKind: .hybridTemplate,
        attemptedKinds: [.scene, .hybridTemplate],
        selectedPath: "hybrid-template.html"
    ))
}

@Test("Runtime planner still supports plain available-kind selection for policy-only callers")
func runtimePlannerSelectsFromKindSet() {
    let planner = ASKPageRuntimePlanner()
    let selection = planner.select(availableKinds: [.markdown, .hybridTemplate])

    #expect(selection == .init(
        selectedKind: .hybridTemplate,
        attemptedKinds: [.scene, .hybridTemplate]
    ))
}

@Test("Runtime planner returns nil when no selectable artifact exists")
func runtimePlannerReturnsNilWithoutArtifacts() {
    let planner = ASKPageRuntimePlanner()
    let manifest = ASKPageRuntimeManifest(documentJSONPath: "document.json")

    #expect(planner.selectArtifact(in: manifest) == nil)
}
