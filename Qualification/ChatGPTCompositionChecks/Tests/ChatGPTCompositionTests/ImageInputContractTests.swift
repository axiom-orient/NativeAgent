@testable import ChatGPTAccount
@testable import ChatGPTText
@testable import ChatGPTImage
@testable import ChatGPTTextProvider
@testable import ChatGPTImageCapability
import Foundation
import Testing
import NativeAgentDomain
import LanguageModelCore

@Suite("Image input admission: no silent fallback")
struct ImageInputContractTests {
  @Test func defaultsAndNormalizationAreExplicit() throws {
    let result = try ChatGPTGenerateImageToolArguments(.object(["prompt": .string("  subject \n")]))
    #expect(result.prompt == "subject")
    #expect(result.background == .auto && result.quality == .auto)
    #expect(result.size == "auto" && result.outputFilename == nil)
    #expect(try ChatGPTImageInputPolicy.size(" 001024X000768 ") == "1024x768")
  }

  @Test func absentValuesUseOnlyTheSuppliedDefaults() throws {
    let result = try ChatGPTGenerateImageToolArguments(.object(["prompt": .string("subject")]),
      defaultBackground: .transparent, defaultQuality: .high, defaultSize: "2x1")
    #expect(result.background == .transparent && result.quality == .high && result.size == "2x1")
  }

  @Test(arguments: ["background", "quality", "size", "output_filename"])
  func wrongTypesAreNotDefaults(_ key: String) {
    for value in [JSONValue.null, .integer(1), .bool(false), .array([]), .object([:])] {
      #expect(throws: AgentError.self) {
        _ = try ChatGPTGenerateImageToolArguments(.object(["prompt": .string("subject"), key: value]))
      }
    }
  }

  @Test func unknownFieldAndMissingPromptAreRejected() {
    for value in [JSONValue.array([]), .object([:]),
      .object(["prompt": .string("subject"), "unapproved": .bool(true)])] {
      #expect(throws: AgentError.self) { _ = try ChatGPTGenerateImageToolArguments(value) }
    }
  }

  @Test(arguments: ["", "  ", "0x1", "1x0", "-1x2", "1.5x2", "1x2x3", "1 x2", "x2", "1x", "9999999999999999999999999999x1"])
  func malformedSizeCannotBecomeAuto(_ size: String) {
    #expect(throws: AgentError.self) { _ = try ChatGPTImageInputPolicy.size(size) }
  }

  @Test func promptUsesUTF8BytesAndRejectsNUL() throws {
    let maximum = ChatGPTImageClient.maximumPromptUTF8Bytes
    #expect(try ChatGPTImageInputPolicy.prompt(String(repeating: "a", count: maximum)).utf8.count == maximum)
    for value in [String(repeating: "a", count: maximum + 1), String(repeating: "한", count: maximum / 3 + 1), "a\0b", " \n"] {
      #expect(throws: AgentError.self) { _ = try ChatGPTImageInputPolicy.prompt(value) }
    }
  }

  @Test(arguments: ["../a.png", "a/b.png", "a\\b.png", "a\0b.png", "a\nb.png", "  "])
  func filenameCannotEscapeOrHideControls(_ filename: String) {
    #expect(throws: AgentError.self) { _ = try ChatGPTImageInputPolicy.filename(filename, maximumCharacters: 128) }
  }

  @Test func filenameIsBoundedByCharactersAndFilesystemBytes() throws {
    #expect(try ChatGPTImageInputPolicy.filename(" layer.png ", maximumCharacters: 128) == "layer.png")
    #expect(throws: AgentError.self) { _ = try ChatGPTImageInputPolicy.filename(String(repeating: "a", count: 129), maximumCharacters: 128) }
    #expect(throws: AgentError.self) { _ = try ChatGPTImageInputPolicy.filename(String(repeating: "한", count: 86), maximumCharacters: 128) }
  }

  @Test func PNGSuffixLimitIsCheckedBeforeDispatch() throws {
    let result = try ChatGPTGenerateImageToolArguments(.object([
      "prompt": .string("subject"), "output_filename": .string("layer"),
    ]))
    #expect(result.outputFilename == "layer.png")
    #expect(throws: AgentError.self) {
      _ = try ChatGPTGenerateImageToolArguments(.object([
        "prompt": .string("subject"), "output_filename": .string(String(repeating: "한", count: 85)),
      ]))
    }
  }

  @Test func framedButUndecodablePNGIsNotAnAdmittedEditInput() {
    #expect(throws: AgentError.self) {
      _ = try ChatGPTEditImageToolArguments.decodeImage(
        PNGTestFixture.inline(PNGTestFixture.framed(imageData: [1, 2, 3])), context: PNGTestFixture.context())
    }
  }

  @Test func inlineInputPreservesExactBytes() throws {
    let bytes = PNGTestFixture.png()
    let image = try ChatGPTEditImageToolArguments.decodeImage(PNGTestFixture.inline(bytes), context: PNGTestFixture.context())
    #expect(image.mimeType == "image/png" && image.data == bytes && image.filename == nil)
  }

  @Test func imageSourceIsExclusiveAndDigestBelongsOnlyToArtifacts() throws {
    let valid = try #require(PNGTestFixture.inline().objectValue)
    var both = valid; both["artifact_relative_path"] = .string("sessions/layer-tests/artifacts/input.png")
    var inlineDigest = valid; inlineDigest["sha256"] = .string(String(repeating: "a", count: 64))
    var wrongMIME = valid; wrongMIME["mime_type"] = .string("image/jpeg")
    let noSource: [String: JSONValue] = ["mime_type": .string("image/png")]
    let noDigest: [String: JSONValue] = ["mime_type": .string("image/png"), "artifact_relative_path": .string("sessions/layer-tests/artifacts/input.png")]
    for value in [both, inlineDigest, wrongMIME, noSource, noDigest] {
      #expect(throws: AgentError.self) { _ = try ChatGPTEditImageToolArguments.decodeImage(.object(value), context: PNGTestFixture.context()) }
    }
  }

  @Test func invalidBase64OrPNGAndInvalidImageCountsFailBeforeDispatch() {
    for base64 in ["%%%", "", Data([1, 2, 3]).base64EncodedString()] {
      #expect(throws: AgentError.self) {
        _ = try ChatGPTEditImageToolArguments.decodeImage(.object(["mime_type": .string("image/png"), "base64": .string(base64)]), context: PNGTestFixture.context())
      }
    }
    for count in [0, ChatGPTImageClient.maximumEditImages + 1] {
      #expect(throws: AgentError.self) {
        _ = try ChatGPTEditImageToolArguments(.object(["prompt": .string("edit"),
          "images": .array(Array(repeating: PNGTestFixture.inline(), count: count))]), context: PNGTestFixture.context())
      }
    }
  }
}
