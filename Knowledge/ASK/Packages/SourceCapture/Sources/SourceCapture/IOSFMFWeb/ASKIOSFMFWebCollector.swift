import Foundation
import KnowledgeCore

public struct ASKIOSFMFWebCollector: Sendable {
    public init() {}

    public func captureHTML(
        _ html: String,
        pageURL: String,
        sourceID: String,
        observedAt: String,
        rawRelpath: String? = nil
    ) throws -> WebCaptureBundle {
        let resolvedRawRelpath = rawRelpath ?? defaultRawRelpath(sourceID: sourceID, observedAt: observedAt)
        return try WebCapture.captureHTMLText(
            html,
            pageURL: pageURL,
            sourceID: sourceID,
            observedAt: observedAt,
            rawRelpath: resolvedRawRelpath
        )
    }

    @discardableResult
    public func stageCapture(root: URL, bundle: WebCaptureBundle) throws -> StagedCapturePaths {
        try CaptureStager.stage(bundle, at: root)
    }
}
