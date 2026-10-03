import NativeAgentDomain
import Foundation

public struct NFCNDEFRecord: Codable, Sendable, Equatable {
    public let typeNameFormat: UInt8
    public let type: String?
    public let identifierBase64: String
    public let payloadBase64: String
    public let wellKnownURI: String?

    public init(
        typeNameFormat: UInt8,
        type: String?,
        identifierBase64: String,
        payloadBase64: String,
        wellKnownURI: String?
    ) {
        self.typeNameFormat = typeNameFormat
        self.type = type
        self.identifierBase64 = identifierBase64
        self.payloadBase64 = payloadBase64
        self.wellKnownURI = wellKnownURI
    }
}

/// One foreground, user-approved NDEF scan. It intentionally excludes raw tag
/// commands, payment tags, and write operations.
@MainActor
public protocol NFCNDEFReadingToolService: AnyObject, Sendable {
    func readSingleMessage() async throws -> [NFCNDEFRecord]
}

public struct NFCNDEFReaderToolPack: ToolPack {
    public let packID: String
    private let service: any NFCNDEFReadingToolService

    public init(
        service: any NFCNDEFReadingToolService,
        packID: String = "toolpack.nfc.ndef"
    ) throws {
        try validatePackID(packID)
        self.service = service
        self.packID = packID
    }

    public func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: definition) { call, _ in
                guard call.arguments.objectValue?.isEmpty == true else {
                    throw AgentError.invalidToolCall("nfc.readNDEF does not accept arguments.")
                }
                let records = try await service.readSingleMessage()
                return ToolResult(
                    callID: call.id,
                    toolName: call.name,
                    output: .object(["records": try JSONValue.encode(records)]),
                    metadata: ["sensitiveData": .bool(true), "foregroundInteraction": .bool(true)]
                )
            },
        ]
    }

    private var definition: ToolDefinition {
        ToolDefinition(
            name: "nfc.readNDEF",
            description: "Start one user-visible foreground scan for a single NFC NDEF message. It cannot write tags or issue raw NFC commands.",
            capabilityID: .nfc,
            inputSchema: ToolSchema.object(properties: [:]),
            approvalPolicy: .requireApproval,
            effect: .readOnly,
            metadata: ["foregroundInteraction": .bool(true), "sensitiveData": .bool(true)]
        )
    }
}

#if canImport(CoreNFC)
@preconcurrency import CoreNFC

@available(iOS 17, *)
@MainActor
public final class CoreNFCNDEFReadingToolService: NFCNDEFReadingToolService {
    private let alertMessage: String
    private let maximumRecords: Int
    private let maximumPayloadBytes: Int
    private var activeOperation: NFCNDEFReadingOperation?

    public init(
        alertMessage: String = "Hold your iPhone near an NFC tag.",
        maximumRecords: Int = 16,
        maximumPayloadBytes: Int = 32 * 1_024
    ) throws {
        guard alertMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AgentError.invalidConfiguration("NFC alert message must not be empty.")
        }
        guard (1...64).contains(maximumRecords), maximumPayloadBytes > 0 else {
            throw AgentError.invalidConfiguration("NFC record limits are invalid.")
        }
        self.alertMessage = alertMessage
        self.maximumRecords = maximumRecords
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    public func readSingleMessage() async throws -> [NFCNDEFRecord] {
        guard NFCNDEFReaderSession.readingAvailable else {
            throw AgentError.unsupportedSurface("NDEF reading is unavailable on this device.")
        }
        try requireHostUsageDescription("NFCReaderUsageDescription", capability: "NFC NDEF reading")
        guard activeOperation == nil else {
            throw AgentError.sessionBusy("An NFC scan is already active.")
        }

        let operation = NFCNDEFReadingOperation(
            alertMessage: alertMessage,
            maximumRecords: maximumRecords,
            maximumPayloadBytes: maximumPayloadBytes
        )
        activeOperation = operation
        defer { activeOperation = nil }
        return try await withTaskCancellationHandler(
            operation: { try await operation.begin() },
            onCancel: {
                DispatchQueue.main.async {
                    operation.cancel()
                }
            }
        )
    }
}

@MainActor
private final class NFCNDEFReadingOperation: NSObject {
    private let alertMessage: String
    private let maximumRecords: Int
    private let maximumPayloadBytes: Int
    private var session: NFCNDEFReaderSession?
    private var continuation: CheckedContinuation<[NFCNDEFRecord], any Error>?
    private var isFinished = false

    init(alertMessage: String, maximumRecords: Int, maximumPayloadBytes: Int) {
        self.alertMessage = alertMessage
        self.maximumRecords = maximumRecords
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    func begin() async throws -> [NFCNDEFRecord] {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let session = NFCNDEFReaderSession(
                delegate: self,
                queue: DispatchQueue.main,
                invalidateAfterFirstRead: true
            )
            session.alertMessage = alertMessage

            if isFinished {
                continuation.resume(throwing: CancellationError())
                return
            }
            self.session = session
            self.continuation = continuation
            session.begin()
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func records(from message: NFCNDEFMessage) throws -> [NFCNDEFRecord] {
        guard message.records.count <= maximumRecords else {
            throw AgentError.budgetExceeded("NDEF message exceeds the record limit.")
        }
        var payloadBytes = 0
        var records: [NFCNDEFRecord] = []
        records.reserveCapacity(message.records.count)
        for payload in message.records {
            let nextBytes = payloadBytes + payload.payload.count
            guard nextBytes <= maximumPayloadBytes else {
                throw AgentError.budgetExceeded("NDEF payload exceeds the byte limit.")
            }
            payloadBytes = nextBytes
            records.append(
                NFCNDEFRecord(
                    typeNameFormat: payload.typeNameFormat.rawValue,
                    type: String(data: payload.type, encoding: .utf8),
                    identifierBase64: payload.identifier.base64EncodedString(),
                    payloadBase64: payload.payload.base64EncodedString(),
                    wellKnownURI: payload.wellKnownTypeURIPayload()?.absoluteString
                )
            )
        }
        return records
    }

    private func finish(_ result: Result<[NFCNDEFRecord], any Error>) {
        guard isFinished == false else {
            return
        }
        isFinished = true
        let session = self.session
        self.session = nil
        let continuation = self.continuation
        self.continuation = nil

        // This class deliberately does not implement didDetectTags, so it is
        // an NDEF read-only session. The SDK specifies plain invalidation for
        // this mode rather than the read-write error-message invalidation API.
        session?.invalidate()
        continuation?.resume(with: result)
    }
}

@MainActor
extension NFCNDEFReadingOperation: @preconcurrency NFCNDEFReaderSessionDelegate {
    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: any Error) {
        finish(.failure(mappedError(from: error)))
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        guard let message = messages.first else {
            finish(.failure(AgentError.notFound("No NDEF message was detected.")))
            return
        }
        do {
            let records = try records(from: message)
            finish(.success(records))
        } catch {
            finish(.failure(error))
        }
    }

    private func mappedError(from error: any Error) -> any Error {
        guard let readerError = error as? NFCReaderError else {
            return AgentError.modelFailure("NFC reader session ended: \(error.localizedDescription)")
        }
        switch readerError.code {
        case .readerSessionInvalidationErrorUserCanceled,
             .readerSessionInvalidationErrorSessionTerminatedUnexpectedly:
            return CancellationError()
        case .readerSessionInvalidationErrorSystemIsBusy:
            return AgentError.sessionBusy("NFC is temporarily busy. Retry after the active reader session ends.")
        case .readerErrorSecurityViolation, .readerErrorAccessNotAccepted:
            return AgentError.accessDenied("NFC requires the host entitlement and user-approved privacy access.")
        case .readerErrorUnsupportedFeature, .readerErrorRadioDisabled, .readerErrorIneligible:
            return AgentError.unsupportedSurface("NFC NDEF reading is unavailable on this device.")
        default:
            return AgentError.modelFailure("NFC reader session ended: \(readerError.localizedDescription)")
        }
    }
}
#endif
