import XCTest
import LEAPProvider
import ModelArtifactStore
final class LiveTests: XCTestCase {
  func testVoiceCancellationDrainsAndReloads() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-cancel-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = LeapRuntime(store: try ModelArtifactStore(rootURL: root))
    try await owner.importModel(.pinned, from: Bundle.main.bundleURL)
    let generator = owner.generator(for: .pinned)
    do {
      let consumer = Task {
        var observedPCM = false
        do {
          for try await event in generator.events(for: .synthesizeEnglish(
            text: "The blue bird sings in the garden. The green trees sway in the gentle breeze.", voice: .usFemale)) {
            if case .pcm(let samples, _) = event, !samples.isEmpty, !observedPCM {
              observedPCM = true
              withUnsafeCurrentTask { $0?.cancel() }
            }
          }
        } catch is CancellationError {
          // Stream cancellation may terminate with an error or normal EOF.
        } catch LeapError.generationInterrupted { }
        return observedPCM && Task.isCancelled
      }
      let cancelledAfterPCM = try await consumer.value
      XCTAssertTrue(cancelledAfterPCM)
      try await owner.unload()
      print("VOICE_CANCEL pcm=observed consumer=cancelled drain=closed")
      try await owner.load(LeapVoiceModel.pinned)
      var completed = false
      var samples = 0
      for try await event in generator.events(for: .synthesizeEnglish(text: "Hello again.", voice: .usFemale)) {
        if case .pcm(let pcm, _) = event { samples += pcm.count }
        if case .completed = event { completed = true }
      }
      XCTAssertTrue(completed && samples > 0)
      try await owner.unload()
      print("VOICE_CANCEL reload=observed generation=completed cleanup=closed")
    } catch { try await owner.unload(); throw error }
  }

  func testVoiceRoundTrip() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-live-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = LeapRuntime(store: try ModelArtifactStore(rootURL: root))
    try await owner.importModel(LeapVoiceModel.pinned, from: Bundle.main.bundleURL)
    print("VOICE_LIVE imported=verified")
    let generator = owner.generator(for: .pinned)
    do {
      var samples: [Float] = []; var rate = 0; var completed = false
      for try await event in generator.events(for: .synthesizeEnglish(text: "The blue bird sings in the garden.", voice: .usFemale)) {
        switch event {
        case .pcm(let pcm, let sampleRate):
          XCTAssertTrue(rate == 0 || rate == sampleRate); rate = sampleRate; samples += pcm
        case .completed: completed = true
        default: break
        }
      }
      XCTAssertTrue(completed && !samples.isEmpty && samples.allSatisfy(\.isFinite))
      XCTAssertTrue(samples.contains { abs($0) > 0.001 })
      print("VOICE_LIVE tts samples=\(samples.count) rate=\(rate) completed=\(completed)")
      let input = try LeapAudioInput(samples: samples, sampleRate: rate)
      var transcript = ""; completed = false
      for try await event in generator.events(for: .transcribeEnglish(audio: input)) {
        if case .transcriptDelta(let delta) = event { transcript += delta }
        if case .completed = event { completed = true }
      }
      print("VOICE_LIVE asr=\(transcript) completed=\(completed)")
      XCTAssertTrue(completed && transcript.lowercased().contains("blue") && transcript.lowercased().contains("garden"))
      var response = ""; var audioCount = 0; completed = false
      for try await event in generator.events(for: .speechToSpeechEnglish(audio: input)) {
        if case .textDelta(let delta) = event { response += delta }
        if case .pcm(let pcm, _) = event { audioCount += pcm.count }
        if case .completed = event { completed = true }
      }
      print("VOICE_LIVE s2s=\(response) samples=\(audioCount) completed=\(completed)")
      XCTAssertTrue(completed && !response.isEmpty && audioCount > 0)
      try await owner.unload()
      print("VOICE_LIVE cleanup=closed")
    } catch { print("VOICE_LIVE failure=\(error)"); try await owner.unload(); throw error }
  }
}
