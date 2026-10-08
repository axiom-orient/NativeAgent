#if canImport(WebKit)
import CoreGraphics
import Foundation
import Testing
import WebKit
#if canImport(UIKit)
import UIKit
private typealias SnapshotFixtureImage = UIImage
#elseif canImport(AppKit)
import AppKit
private typealias SnapshotFixtureImage = NSImage
#endif
@testable import NativeAgentBrowser

/// Controlled callback ordering only; real native pixels are checked separately.
@MainActor
private final class DeferredSnapshotWebView: WKWebView {
    private(set) var completions: [@MainActor @Sendable (SnapshotFixtureImage?, (any Error)?) -> Void] = []

    override func takeSnapshot(
        with snapshotConfiguration: WKSnapshotConfiguration?,
        completionHandler: @escaping @MainActor @Sendable (SnapshotFixtureImage?, (any Error)?) -> Void
    ) {
        completions.append(completionHandler)
    }
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func cancelledSnapshotCallbackCannotCompleteTheNextCapture() async throws {
    let view = DeferredSnapshotWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    let runner = BrowserSnapshotRunner()
    let first = Task { @MainActor in
        try await runner.capturePNG(in: view, maximumBytes: 4096, timeout: .seconds(10))
    }
    while view.completions.isEmpty { await Task.yield() }
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }

    let second = Task { @MainActor in
        try await runner.capturePNG(in: view, maximumBytes: 4096, timeout: .seconds(10))
    }
    while view.completions.count < 2 { await Task.yield() }
    let oldImage = try snapshotFixtureImage(red: 255, green: 0)
    let currentImage = try snapshotFixtureImage(red: 0, green: 255)
    view.completions[0](oldImage, nil)
    view.completions[1](currentImage, nil)
    let data = try await second.value
    #if canImport(UIKit)
    let image = try #require(UIImage(data: data)?.cgImage)
    #elseif canImport(AppKit)
    let image = try #require(NSBitmapImageRep(data: data)?.cgImage)
    #endif
    var pixel = [UInt8](repeating: 0, count: 4)
    try pixel.withUnsafeMutableBytes { buffer in
        let context = try #require(CGContext(
            data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    #expect(pixel[0] < 12)
    #expect(pixel[1] > 243)
}

@MainActor
private func snapshotFixtureImage(red: UInt8, green: UInt8) throws -> SnapshotFixtureImage {
    var pixel: [UInt8] = [red, green, 0, 255]
    let image = try pixel.withUnsafeMutableBytes { buffer in
        let context = try #require(CGContext(
            data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }
    #if canImport(UIKit)
    return UIImage(cgImage: image)
    #else
    return NSImage(cgImage: image, size: CGSize(width: 1, height: 1))
    #endif
}
#endif
