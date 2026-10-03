import Foundation
import KnowledgeRuntime

public actor ASKIOSFMFImportPipeline {
    package let kernel: ASKIOSFMFKernel
    package let collector: ASKIOSFMFWebCollector

    public init(root: URL) {
        self.kernel = ASKIOSFMFKernel(root: root)
        self.collector = ASKIOSFMFWebCollector()
    }

    @discardableResult
    public func captureStageAndImport(
        html: String,
        pageURL: String,
        sourceID: String,
        observedAt: String,
        stagingRoot: URL
    ) async throws -> ASKImportedCapture {
        let bundle = try capturePhase(
            html: html,
            pageURL: pageURL,
            sourceID: sourceID,
            observedAt: observedAt
        )
        let stagedPaths = try stagePhase(stagingRoot: stagingRoot, bundle: bundle)
        return try await importPhase(stagedPaths: stagedPaths)
    }
}
