import XCTest

@testable import NativeAgentMLXDeviceQualification

final class NativeAgentMLXDeviceQualificationTests: XCTestCase {
  func testPhysicalDeviceRunsMLXThroughNativeAgentAndReloadsSession() async throws {
    #if targetEnvironment(simulator)
      throw XCTSkip("The MLX qualification requires a physical iOS device with Metal support.")
    #else
      let receipt = try await NativeAgentMLXDeviceQualificationRunner.run()
      XCTAssertEqual(receipt.sourceIdentity.utf8.count, 64)
      XCTAssertEqual(
        receipt.modelRepositoryID,
        NativeAgentMLXDeviceQualificationRunner.modelRepositoryID
      )
      XCTAssertEqual(
        receipt.modelRevision,
        NativeAgentMLXDeviceQualificationRunner.modelRevision
      )
      XCTAssertEqual(receipt.firstStatus, "completed")
      XCTAssertGreaterThan(receipt.outputByteCount, 0)
      XCTAssertTrue(receipt.requiredTokenObserved)
      XCTAssertGreaterThanOrEqual(receipt.restoredMessageCount, 3)
      XCTAssertTrue(receipt.cancellationDrainObserved)
      XCTAssertTrue(receipt.cleanupObserved)
    #endif
  }
  func testQwen35FilesToolRoundTrip() async throws {
    #if targetEnvironment(simulator)
      throw XCTSkip("Physical MLX device required.")
    #else
      try await MLXFeatureQualification.files()
    #endif
  }
  func testQwen35Manager() async throws {
    #if targetEnvironment(simulator)
      throw XCTSkip("Physical MLX device required.")
    #else
      try await MLXFeatureQualification.manager()
    #endif
  }
  func testQwen35Memory() async throws {
    #if targetEnvironment(simulator)
      throw XCTSkip("Physical MLX device required.")
    #else
      try await MLXFeatureQualification.memory()
    #endif
  }
  func testQwen35Goals() async throws {
    #if targetEnvironment(simulator)
      throw XCTSkip("Physical MLX device required.")
    #else
      try await MLXFeatureQualification.goals()
    #endif
  }
  func testQwen35Evolution() async throws {
    #if targetEnvironment(simulator)
      throw XCTSkip("Physical MLX device required.")
    #else
      try await MLXFeatureQualification.evolution()
    #endif
  }
  func testQwen35StructuredOutput() async throws {
    #if targetEnvironment(simulator)
      throw XCTSkip("Physical MLX device required.")
    #else
      try await MLXFeatureQualification.structuredOutput()
    #endif
  }
  func testQwen35Consensus() async throws {
    #if targetEnvironment(simulator)
      throw XCTSkip("Physical MLX device required.")
    #else
      try await MLXFeatureQualification.consensus()
    #endif
  }
}

#if os(iOS)
import UIKit
import CoreImage
import NativeAgentTools

extension NativeAgentMLXDeviceQualificationTests {
  @MainActor
  func testRealDeviceVisionOCRAndQR() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vision-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 200))
    let image = renderer.image { context in
      UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 200))
      ("NATIVE AGENT VISION 4729" as NSString).draw(at: CGPoint(x: 30, y: 60), withAttributes: [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black])
    }
    let textURL = root.appendingPathComponent("text.png")
    try XCTUnwrap(image.pngData()).write(to: textURL)
    let service = AppleVisionAnalysisToolService()
    let recognized = try await service.recognizeText(in: textURL, languages: ["en-US"], maximumResults: 10)
    XCTAssertTrue(recognized.contains { $0.text.contains("VISION 4729") })
    let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
    filter.setValue(Data("native-agent-qr-4729".utf8), forKey: "inputMessage")
    let qr = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 12, y: 12))
    let qrURL = root.appendingPathComponent("qr.png")
    try CIContext().writePNGRepresentation(of: qr, to: qrURL, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    let codes = try await service.detectBarcodes(in: qrURL, maximumResults: 10)
    XCTAssertTrue(codes.contains { $0.payload == "native-agent-qr-4729" })
    print("NATIVE_AGENT_DEVICE_VISION_PASS actualOCR=observed actualQR=observed")
  }

  func testRealDeviceMapKitSearch() async throws {
    let service = MapKitSearchToolService()
    let region = try MapSearchRegion(latitude: 48.8584, longitude: 2.2945, latitudeDelta: 0.02, longitudeDelta: 0.02)
    let results = try await service.search(MapSearchRequest(query: "Eiffel Tower", region: region), maximumResults: 50)
    XCTAssertTrue(results.contains { abs($0.latitude - 48.8584) < 0.02 && abs($0.longitude - 2.2945) < 0.02 })
    print("NATIVE_AGENT_DEVICE_MAPKIT_PASS actualSearch=observed")
  }
}
#endif

extension NativeAgentMLXDeviceQualificationTests {
  @MainActor
  func testActualAppIntentThroughToolPack() async throws {
    let receipt = try await AppleQualification.runIntent()
    XCTAssertTrue(receipt.hasPrefix("PASS:"))
    print("APPLE_INTENT_DIRECT \(receipt)")
  }
}

extension NativeAgentMLXDeviceQualificationTests {
  func testStructuredCancellationLimitsAndReuse() async throws {
    try await MLXFeatureQualification.structuredCancellationAndLimits()
  }
}

#if os(iOS)
import Speech
extension NativeAgentMLXDeviceQualificationTests {
  @MainActor
  func testSpeechWithExistingAuthorization() async throws {
    guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
      throw XCTSkip("User speech authorization is required in the qualification app.")
    }
    let receipt = try await AppleQualification.runSpeech()
    XCTAssertTrue(receipt.hasPrefix("PASS:"))
  }
}
#endif
