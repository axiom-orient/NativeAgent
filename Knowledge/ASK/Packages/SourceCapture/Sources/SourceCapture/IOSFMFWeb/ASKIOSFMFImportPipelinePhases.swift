import Foundation
import KnowledgeRuntime

package struct ASKIOSFMFImportPhaseState: Sendable, Equatable {
    package var bundle: WebCaptureBundle
    package var stagedPaths: StagedCapturePaths
}

extension ASKIOSFMFImportPipeline {
    package func capturePhase(
        html: String,
        pageURL: String,
        sourceID: String,
        observedAt: String
    ) throws -> WebCaptureBundle {
        try collector.captureHTML(
            html,
            pageURL: pageURL,
            sourceID: sourceID,
            observedAt: observedAt
        )
    }

    package func stagePhase(stagingRoot: URL, bundle: WebCaptureBundle) throws -> StagedCapturePaths {
        try collector.stageCapture(root: stagingRoot, bundle: bundle)
    }

    package func importPhase(stagedPaths: StagedCapturePaths) async throws -> ASKImportedCapture {
        try await kernel.importCollected(stagedPaths.manifestPath)
    }
}
