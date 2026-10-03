import Foundation
import Testing
import DocumentCore
@testable import DocumentRuntime

@Test("DocumentRuntime planner keeps deterministic fallback order")
func runtimePlannerOrderIsDeterministic() {
    let planner = ASKPageRuntimePlanner()
    #expect(planner.preferredArtifactOrder() == [.scene, .hybridTemplate, .fullHTML, .markdown])
}

@Test("DocumentRuntime locations keep the file-system boundary typed")
func runtimeDocumentLocationKeepsFileSystemBoundaryTyped() {
    let location = ASKPageDocumentLocation(rootURL: URL(fileURLWithPath: "/tmp/doc"))
    #expect(location.rootURL.path(percentEncoded: false) == "/tmp/doc")
}
