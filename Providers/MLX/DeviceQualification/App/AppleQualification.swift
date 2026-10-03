import SwiftUI
import AppIntents
import NativeAgentTools
import NativeAgent
import Speech

/// Synthetic fixtures only; this host never records microphone audio.
@MainActor
struct AppleQualificationView: View {
    @State private var status = "아직 실행하지 않음"
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apple 기능 검증").font(.headline)
            Text("합성 음성 파일만 사용합니다. 권한 창이 나타나면 직접 선택하세요.")
            Button("기기 내 음성 인식 검증") {
                running = true
                Task {
                    defer { running = false }
                    do { status = try await AppleQualification.runSpeech() }
                    catch { status = "FAIL: \(error.localizedDescription)" }
                }
            }.disabled(running)
            Button("App Intent 직접 호출 검증") {
                running = true
                Task {
                    defer { running = false }
                    do { status = try await AppleQualification.runIntent() }
                    catch { status = "FAIL: \(error.localizedDescription)" }
                }
            }.disabled(running)
            Text(status).textSelection(.enabled)
            Text("Shortcuts에서 ‘Write qualification proof’를 실행한 뒤 아래에서 실행 기록을 확인하세요. 직접 호출은 Shortcuts 시스템 경로의 통과를 의미하지 않습니다.")
                .font(.caption)
            Button("Shortcuts 실행 기록 확인") {
                do { status = try String(contentsOf: QualificationIntentStore.url, encoding: .utf8) }
                catch { status = "NOT_RUN: 시스템 실행 기록 없음" }
            }
        }
    }
}

@MainActor
enum AppleQualification {
    static func runSpeech() async throws -> String {
        guard let audio = Bundle.main.url(forResource: "speech", withExtension: "wav") else {
            throw QualificationError.missingFixture
        }
        let service = try SFSpeechTranscriptionToolService()
        let result = try await service.transcribe(audioURL: audio,
            localeIdentifier: "en-US", recognitionMode: .onDeviceOnly)
        let normalized = result.text.lowercased()
        guard normalized.contains("blue"), normalized.contains("bird"), normalized.contains("garden") else {
            throw QualificationError.unexpectedTranscript(result.text)
        }
        let receipt = "PASS: on-device ASR — " + result.text
        print("APPLE_SPEECH_QUALIFICATION \(receipt)")
        return receipt
    }

    static func runIntent() async throws -> String {
        let service = QualificationIntentToolService()
        let executor = AppIntentsToolPack(service: service).executors()[0]
        let root = FileManager.default.temporaryDirectory
        let result = try await executor.execute(
            call: ToolCall(id: "intent-proof", name: executor.definition.name, arguments: .object([:])),
            context: ToolExecutionContext(sessionID: "intent-proof", sessionDirectoryURL: root, sandboxRootURL: root))
        guard !result.isError else { throw QualificationError.missingFixture }
        return "PASS: ToolPack → 실제 AppIntent.perform → 파일 읽기 확인. Shortcuts 진입은 별도 검증입니다."
    }
}

private enum QualificationError: Error {
    case missingFixture
    case unexpectedTranscript(String)
}

private enum QualificationIntentStore {
    static var url: URL {
        get throws {
            try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("nativeagent-intent-proof.txt")
        }
    }
    static func write(origin: String) throws -> String {
        let value = "INTENT_OK origin=\(origin) at=\(Date().ISO8601Format())"
        let destination = try url
        try Data(value.utf8).write(to: destination, options: .atomic)
        guard try String(contentsOf: destination, encoding: .utf8) == value else { throw QualificationError.missingFixture }
        return value
    }
}

struct WriteQualificationProofIntent: AppIntent {
    static let title: LocalizedStringResource = "Write qualification proof"
    static let description = IntentDescription("Write and read back a synthetic proof in this qualification app.")
    @Parameter(title: "Origin", default: "shortcuts") var origin: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try QualificationIntentStore.write(origin: origin))
    }
}

struct QualificationShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WriteQualificationProofIntent(),
            phrases: ["Write a proof with \(.applicationName)"],
            shortTitle: "Write qualification proof", systemImageName: "checkmark.seal")
    }
}

private struct QualificationIntentToolService: AppIntentsToolService {
    func toolDefinitions() -> [ToolDefinition] {
        [ToolDefinition(name: "qualification.writeProof", description: "Write synthetic qualification proof.",
            capabilityID: .appIntents, inputSchema: .object(["type": "object", "properties": .object([:]), "additionalProperties": false]),
            approvalPolicy: .requireApproval)]
    }
    func executeIntent(named: String, arguments: JSONValue) async throws -> ToolResult {
        var intent = WriteQualificationProofIntent()
        intent.origin = "direct-toolpack"
        let result = try await intent.perform()
        guard let value = result.value else { throw QualificationError.missingFixture }
        return ToolResult(callID: "intent-proof", toolName: named, output: .string(value))
    }
}
