import Foundation

#if canImport(WebKit)
import WebKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class BrowserSnapshotRunner {
    private var continuation: CheckedContinuation<Data, any Error>?
    private var timeoutTimer: Timer?
    private var operationID: UUID?

    func capturePNG(
        in webView: WKWebView,
        maximumBytes: Int,
        timeout: Duration
    ) async throws -> Data {
        guard continuation == nil else { throw BrowserError.operationInProgress }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.operationID = id
                self.continuation = continuation
                timeoutTimer = Timer.scheduledTimer(
                    withTimeInterval: BrowserTiming.timeInterval(timeout),
                    repeats: false
                ) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.finish(throwing: BrowserError.operationTimedOut, operationID: id)
                    }
                }
                let configuration = WKSnapshotConfiguration()
                // An offscreen view has no guaranteed future presentation update.
                // Capture its rendered content without waiting for that event.
                configuration.afterScreenUpdates = webView.window != nil
                webView.takeSnapshot(with: configuration) { [weak self] image, error in
                    guard let self, operationID == id else { return }
                    if let error {
                        finish(throwing: BrowserError.navigationFailed(error.localizedDescription), operationID: id)
                        return
                    }
                    guard let image, let data = Self.pngData(image) else {
                        finish(throwing: BrowserError.snapshotEncodingFailed, operationID: id)
                        return
                    }
                    guard data.count <= maximumBytes else {
                        finish(throwing: BrowserError.snapshotTooLarge, operationID: id)
                        return
                    }
                    finish(returning: data, operationID: id)
                }
            }
        } onCancel: {
            DispatchQueue.main.async {
                self.finish(throwing: CancellationError(), operationID: id)
            }
        }
    }

    func cancel() {
        guard let operationID else { return }
        finish(throwing: CancellationError(), operationID: operationID)
    }

    private func finish(returning value: Data, operationID: UUID) {
        guard self.operationID == operationID, let continuation else { return }
        reset()
        continuation.resume(returning: value)
    }

    private func finish(throwing error: any Error, operationID: UUID) {
        guard self.operationID == operationID, let continuation else { return }
        reset()
        continuation.resume(throwing: error)
    }

    private func reset() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        continuation = nil
        operationID = nil
    }

    private static func pngData(_ image: Any) -> Data? {
        #if canImport(UIKit)
        (image as? UIImage)?.pngData()
        #elseif canImport(AppKit)
        guard let image = image as? NSImage,
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff) else { return nil }
        return representation.representation(using: .png, properties: [:])
        #else
        nil
        #endif
    }
}
#endif
