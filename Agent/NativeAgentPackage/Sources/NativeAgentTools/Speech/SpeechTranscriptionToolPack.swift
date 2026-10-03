import NativeAgentDomain
import Foundation

public struct SpeechTranscription: Codable, Sendable, Equatable {
    public let text: String
    public let localeIdentifier: String

    public init(text: String, localeIdentifier: String) {
        self.text = text
        self.localeIdentifier = localeIdentifier
    }
}

/// The host fixes this policy at composition time; an agent cannot request a
/// less private recognition mode in a tool call.
public enum SpeechRecognitionMode: String, Codable, Sendable, Equatable {
    /// Fail closed when the selected locale cannot recognize this file on the
    /// device. The audio is not sent to Apple's recognition service.
    case onDeviceOnly
    /// Permit the platform recognition service when the host has chosen to
    /// expose that network-capable surface.
    case systemService
}

@MainActor
public protocol SpeechTranscriptionToolService: AnyObject, Sendable {
    func transcribe(
        audioURL: URL,
        localeIdentifier: String,
        recognitionMode: SpeechRecognitionMode
    ) async throws -> SpeechTranscription
}

public struct SpeechTranscriptionToolPack: ToolPack {
    public let packID: String
    private let service: any SpeechTranscriptionToolService
    private let maximumInputBytes: Int
    private let defaultLocaleIdentifier: String
    private let recognitionMode: SpeechRecognitionMode

    public init(
        service: any SpeechTranscriptionToolService,
        maximumInputBytes: Int = 64 * 1_024 * 1_024,
        defaultLocaleIdentifier: String = Locale.current.identifier,
        recognitionMode: SpeechRecognitionMode = .onDeviceOnly,
        packID: String = "toolpack.speech"
    ) throws {
        try validatePackID(packID)
        guard maximumInputBytes > 0 else {
            throw AgentError.invalidConfiguration("Speech maximum input bytes must be positive.")
        }
        guard Self.isValidLocaleIdentifier(defaultLocaleIdentifier) else {
            throw AgentError.invalidConfiguration("Speech default locale identifier is invalid.")
        }
        self.service = service
        self.maximumInputBytes = maximumInputBytes
        self.defaultLocaleIdentifier = defaultLocaleIdentifier
        self.recognitionMode = recognitionMode
        self.packID = packID
    }

    public func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: definition) { call, context in
                let request = try SpeechTranscriptionRequest(
                    arguments: call.arguments,
                    defaultLocaleIdentifier: defaultLocaleIdentifier
                )
                let audioURL = try ToolWorkspaceFileResolver.readableFile(
                    relativePath: request.path,
                    context: context,
                    maximumByteCount: maximumInputBytes,
                    label: "Speech",
                    allowedExtensions: Self.supportedAudioExtensions
                )
                let transcription = try await service.transcribe(
                    audioURL: audioURL,
                    localeIdentifier: request.localeIdentifier,
                    recognitionMode: recognitionMode
                )
                return ToolResult(
                    callID: call.id,
                    toolName: call.name,
                    output: try JSONValue.encode(transcription),
                    metadata: ["sourcePath": .string(request.path), "sensitiveData": .bool(true)]
                )
            },
        ]
    }

    private var definition: ToolDefinition {
        ToolDefinition(
            name: "speech.transcribeAudio",
            description: description,
            capabilityID: .speech,
            inputSchema: ToolSchema.object(
                properties: [
                    "path": ToolSchema.string(description: "Relative audio file path in the current session workspace.", minLength: 1, maxLength: 1_024),
                    "localeIdentifier": ToolSchema.string(description: "Optional BCP-47 speech-recognition locale.", minLength: 2, maxLength: 35),
                ],
                required: ["path"]
            ),
            approvalPolicy: .requireApproval,
            effect: .readOnly,
            metadata: [
                "sensitiveData": .bool(true),
                "localOnly": .bool(recognitionMode == .onDeviceOnly),
                "networkAccess": .bool(recognitionMode == .systemService),
            ]
        )
    }

    private var description: String {
        switch recognitionMode {
        case .onDeviceOnly:
            "Transcribe one bounded audio file in the current agent session on-device after speech-recognition approval. It never records from the microphone or sends audio through this tool."
        case .systemService:
            "Transcribe one bounded audio file in the current agent session with the host-approved platform speech service. It never records from the microphone."
        }
    }

    private static let supportedAudioExtensions: Set<String> = [
        "aac", "aif", "aiff", "caf", "m4a", "mp3", "mp4", "wav",
    ]

    fileprivate static func isValidLocaleIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (2...35).contains(trimmed.unicodeScalars.count)
            && trimmed.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
            }
    }
}

private struct SpeechTranscriptionRequest {
    let path: String
    let localeIdentifier: String

    init(arguments: JSONValue, defaultLocaleIdentifier: String) throws {
        let object = try requiredObject(arguments, toolName: "speech.transcribeAudio")
        try rejectUnknownKeys(object, allowed: ["path", "localeIdentifier"], toolName: "speech.transcribeAudio")
        guard let path = object["path"]?.stringValue,
              path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AgentError.invalidToolCall("speech.transcribeAudio requires a non-empty path.")
        }
        let localeIdentifier = object["localeIdentifier"]?.stringValue ?? defaultLocaleIdentifier
        guard SpeechTranscriptionToolPack.isValidLocaleIdentifier(localeIdentifier) else {
            throw AgentError.invalidToolCall("speech.transcribeAudio localeIdentifier is invalid.")
        }
        self.path = path
        self.localeIdentifier = localeIdentifier
    }
}

#if canImport(Speech)
import AVFoundation
@preconcurrency import Speech

@available(iOS 17, *)
@MainActor
public final class SFSpeechTranscriptionToolService: SpeechTranscriptionToolService {
    private let maximumAudioDuration: TimeInterval
    private var activeOperation: SpeechRecognitionOperation?

    /// Apple's speech service has a one-minute recognition limit. Keep the
    /// limit host-configurable, but never let this adapter submit a longer
    /// file and rely on a late service-side failure.
    public init(maximumAudioDuration: TimeInterval = 60) throws {
        guard maximumAudioDuration > 0, maximumAudioDuration <= 60 else {
            throw AgentError.invalidConfiguration("Speech maximum audio duration must be between zero and 60 seconds.")
        }
        self.maximumAudioDuration = maximumAudioDuration
    }

    public func transcribe(
        audioURL: URL,
        localeIdentifier: String,
        recognitionMode: SpeechRecognitionMode
    ) async throws -> SpeechTranscription {
        guard activeOperation == nil else {
            throw AgentError.sessionBusy("A speech transcription is already active.")
        }
        try await validateAudioDuration(audioURL)
        try await requireAuthorization()
        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw AgentError.unavailableProvider("Speech recognition is unavailable for \(localeIdentifier).")
        }
        if recognitionMode == .onDeviceOnly, recognizer.supportsOnDeviceRecognition == false {
            throw AgentError.unsupportedSurface(
                "On-device speech recognition is unavailable for \(localeIdentifier). The host must explicitly opt in to system-service recognition."
            )
        }

        let operation = SpeechRecognitionOperation()
        activeOperation = operation
        defer { activeOperation = nil }
        return try await withTaskCancellationHandler(
            operation: {
                try await operation.transcribe(
                    audioURL: audioURL,
                    recognizer: recognizer,
                    localeIdentifier: localeIdentifier,
                    recognitionMode: recognitionMode
                )
            },
            onCancel: {
                DispatchQueue.main.async {
                    operation.cancel()
                }
            }
        )
    }

    private func requireAuthorization() async throws {
        try requireHostUsageDescription("NSSpeechRecognitionUsageDescription", capability: "Speech recognition")
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
        guard status == .authorized else {
            throw AgentError.accessDenied("Speech recognition access was not granted.")
        }
    }

    private func validateAudioDuration(_ audioURL: URL) async throws {
        let asset = AVURLAsset(url: audioURL)
        let duration = try await asset.load(.duration)
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else {
            throw AgentError.invalidToolCall("Speech input does not contain a finite audio duration.")
        }
        guard seconds <= maximumAudioDuration else {
            throw AgentError.budgetExceeded(
                "Speech input duration \(seconds) seconds exceeds the host limit of \(maximumAudioDuration) seconds."
            )
        }
    }
}

@MainActor
private final class SpeechRecognitionOperation {
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<SpeechTranscription, any Error>?
    private var isFinished = false

    func transcribe(
        audioURL: URL,
        recognizer: SFSpeechRecognizer,
        localeIdentifier: String,
        recognitionMode: SpeechRecognitionMode
    ) async throws -> SpeechTranscription {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: audioURL)
            request.shouldReportPartialResults = false
            request.requiresOnDeviceRecognition = recognitionMode == .onDeviceOnly
            let task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                let errorDescription = error?.localizedDescription
                let finalText = result?.isFinal == true ? result?.bestTranscription.formattedString : nil
                guard errorDescription != nil || finalText != nil else { return }
                DispatchQueue.main.async {
                    if let errorDescription {
                        self?.finish(.failure(AgentError.modelFailure("Speech recognition failed: \(errorDescription)")))
                    } else if let finalText {
                        self?.finish(
                            .success(
                                SpeechTranscription(
                                    text: finalText,
                                    localeIdentifier: localeIdentifier
                                )
                            )
                        )
                    }
                }
            }
            if isFinished {
                task.cancel()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.task = task
            self.continuation = continuation
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<SpeechTranscription, any Error>) {
        guard isFinished == false else {
            return
        }
        isFinished = true
        let task = self.task
        self.task = nil
        let continuation = self.continuation
        self.continuation = nil

        task?.cancel()
        continuation?.resume(with: result)
    }
}
#endif
