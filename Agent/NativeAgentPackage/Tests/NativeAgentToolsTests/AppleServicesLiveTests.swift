#if os(macOS)
import AppKit
import CoreImage
import Foundation
import Testing
@testable import NativeAgentTools

/// Explicit opt-in: these probes call the real Apple frameworks and MapKit network.
struct AppleServicesLiveTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["NATIVEAGENT_LIVE_APPLE"] == "1"))
  @MainActor
  func realVisionTextAndBarcode() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let textURL = root.appendingPathComponent("text.png")
    let bitmap = try #require(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 200, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 1000, height: 200).fill()
    ("NATIVE AGENT VISION 4729" as NSString).draw(
      at: NSPoint(x: 30, y: 70),
      withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState()
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: textURL)
    let service = AppleVisionAnalysisToolService()
    let text = try await service.recognizeText(in: textURL, languages: ["en-US"], maximumResults: 10)
    #expect(text.contains { $0.text.contains("VISION 4729") })
    #expect(text.allSatisfy { $0.confidence > 0 && $0.boundingBox.width > 0 })

    let payload = "native-agent-qr-4729"
    let filter = try #require(CIFilter(name: "CIQRCodeGenerator"))
    filter.setValue(Data(payload.utf8), forKey: "inputMessage")
    let qr = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 12, y: 12))
    let qrURL = root.appendingPathComponent("qr.png")
    try CIContext().writePNGRepresentation(of: qr, to: qrURL, format: .RGBA8,
      colorSpace: CGColorSpaceCreateDeviceRGB())
    let codes = try await service.detectBarcodes(in: qrURL, maximumResults: 10)
    #expect(codes.contains { $0.payload == payload })
    print("NATIVE_AGENT_APPLE_VISION_PASS text=observed qr=observed")
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["NATIVEAGENT_LIVE_APPLE"] == "1"))
  @available(macOS 26, *)
  func realMapKitSearch() async throws {
    let service = MapKitSearchToolService()
    let region = try MapSearchRegion(latitude: 48.8584, longitude: 2.2945,
      latitudeDelta: 0.02, longitudeDelta: 0.02)
    let results = try await service.search(
      MapSearchRequest(query: "Eiffel Tower", region: region), maximumResults: 50)
    #expect(!results.isEmpty)
    #expect(results.contains { abs($0.latitude - 48.8584) < 0.02 && abs($0.longitude - 2.2945) < 0.02 })
    print("NATIVE_AGENT_MAPKIT_PASS results=\(results.count) expectedRegion=observed")
  }
}
#endif
