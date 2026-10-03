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

    func capturePNG(
        in webView: WKWebView,
        maximumBytes: Int,
        timeout: Duration
    ) async throws -> Data {
        guard continuation == nil else { throw BrowserError.operationInProgress }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeoutTimer = Timer.scheduledTimer(
                    withTimeInterval: BrowserTiming.timeInterval(timeout),
                    repeats: false
                ) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.finish(throwing: BrowserError.operationTimedOut)
                    }
                }
                webView.takeSnapshot(with: nil) { [weak self] image, error in
                    guard let self else { return }
                    if let error {
                        finish(throwing: BrowserError.navigationFailed(error.localizedDescription))
                        return
                    }
                    guard let image, let data = Self.pngData(image) else {
                        finish(throwing: BrowserError.snapshotEncodingFailed)
                        return
                    }
                    guard data.count <= maximumBytes else {
                        finish(throwing: BrowserError.snapshotTooLarge)
                        return
                    }
                    finish(returning: data)
                }
            }
        } onCancel: {
            DispatchQueue.main.async {
                self.cancel()
            }
        }
    }

    func cancel() {
        finish(throwing: CancellationError())
    }

    private func finish(returning value: Data) {
        guard let continuation else { return }
        reset()
        continuation.resume(returning: value)
    }

    private func finish(throwing error: any Error) {
        guard let continuation else { return }
        reset()
        continuation.resume(throwing: error)
    }

    private func reset() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        continuation = nil
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
