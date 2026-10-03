import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentTools

@Test @MainActor
func appleToolPacksExposeSeparateNarrowCapabilities() throws {
    let photoPack = try PhotoLibraryToolPack(service: PhotoServiceStub())
    let healthPack = try HealthSummaryToolPack(service: HealthServiceStub())
    let visionPack = try VisionAnalysisToolPack(service: VisionServiceStub())
    let speechPack = try SpeechTranscriptionToolPack(service: SpeechServiceStub(), defaultLocaleIdentifier: "en-US")
    let mapPack = try MapSearchToolPack(service: MapServiceStub())
    let nfcPack = try NFCNDEFReaderToolPack(service: NFCServiceStub())

    let definitions = [
        photoPack.executors().first!.definition,
        healthPack.executors().first!.definition,
        visionPack.executors()[0].definition,
        visionPack.executors()[1].definition,
        speechPack.executors().first!.definition,
        mapPack.executors().first!.definition,
        nfcPack.executors().first!.definition,
    ]

    #expect(definitions.map(\.name) == [
        "photos.listAssets",
        "health.aggregateQuantity",
        "vision.recognizeText",
        "vision.detectBarcodes",
        "speech.transcribeAudio",
        "maps.search",
        "nfc.readNDEF",
    ])
    #expect(definitions.map(\.capabilityID) == [.photos, .health, .vision, .vision, .speech, .maps, .nfc])
    #expect(definitions.allSatisfy { $0.approvalPolicy == .requireApproval })
    #expect(definitions.allSatisfy { $0.isReadOnly })
    #expect(definitions[4].metadata["localOnly"]?.boolValue == true)
    #expect(definitions[4].metadata["networkAccess"]?.boolValue == false)
    #expect(definitions[5].metadata["sensitiveData"]?.boolValue != true)
    for index in [0, 1, 2, 3, 4, 6] {
        #expect(definitions[index].metadata["sensitiveData"]?.boolValue == true)
    }

    let systemSpeechPack = try SpeechTranscriptionToolPack(
        service: SpeechServiceStub(),
        defaultLocaleIdentifier: "en-US",
        recognitionMode: .systemService
    )
    let systemSpeechDefinition = try #require(systemSpeechPack.executors().first?.definition)
    #expect(systemSpeechDefinition.metadata["localOnly"]?.boolValue == false)
    #expect(systemSpeechDefinition.metadata["networkAccess"]?.boolValue == true)
}

@Test @MainActor
func photosAndHealthPacksBoundScopeBeforeInvokingServices() async throws {
    let photoService = PhotoServiceStub()
    let photoPack = try PhotoLibraryToolPack(service: photoService)
    let photoExecutor = try #require(photoPack.executors().first)
    let root = makeToolPackTempRoot()

    let result = try await photoExecutor.execute(
        call: ToolCall(name: "photos.listAssets", arguments: [
            "mediaKind": "image",
            "createdAfter": "2026-01-01T00:00:00Z",
            "createdBefore": "2026-01-02T00:00:00Z",
            "limit": 3,
        ]),
        context: noopContext(root: root)
    )
    #expect(result.output.objectValue?["accessScope"]?.stringValue == "limited")
    #expect(result.output.objectValue?["nextCursor"]?.stringValue == "photos-page-2")
    #expect(result.output.objectValue?["hasMore"]?.boolValue == true)
    #expect((await photoService.lastRequest)?.mediaKind == .image)
    #expect((await photoService.lastRequest)?.limit == 3)

    await #expect(throws: AgentError.self) {
        _ = try await photoExecutor.execute(
            call: ToolCall(name: "photos.listAssets", arguments: ["limit": 0]),
            context: noopContext(root: root)
        )
    }

    let healthService = HealthServiceStub()
    let healthPack = try HealthSummaryToolPack(
        service: healthService,
        allowedMetrics: [.stepCount],
        maximumQueryInterval: 24 * 60 * 60
    )
    let healthExecutor = try #require(healthPack.executors().first)
    let healthResult = try await healthExecutor.execute(
        call: ToolCall(name: "health.aggregateQuantity", arguments: [
            "metric": "stepCount",
            "startDate": "2026-01-01T00:00:00Z",
            "endDate": "2026-01-01T12:00:00Z",
        ]),
        context: noopContext(root: root)
    )
    #expect(healthResult.output.objectValue?["dataMayBeIncomplete"]?.boolValue == true)
    #expect((await healthService.lastQuery)?.metric == .stepCount)

    await #expect(throws: AgentError.self) {
        _ = try await healthExecutor.execute(
            call: ToolCall(name: "health.aggregateQuantity", arguments: [
                "metric": "activeEnergyBurned",
                "startDate": "2026-01-01T00:00:00Z",
                "endDate": "2026-01-01T12:00:00Z",
            ]),
            context: noopContext(root: root)
        )
    }
}

@Test @MainActor
func visionAndSpeechPacksOnlyPassBoundedSessionFilesToServices() async throws {
    let root = makeToolPackTempRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: root.appendingPathComponent("scan.png"))
    try Data([4, 5, 6]).write(to: root.appendingPathComponent("note.m4a"))
    let context = noopContext(root: root)

    let visionService = VisionServiceStub()
    let visionPack = try VisionAnalysisToolPack(service: visionService, maximumInputBytes: 4)
    let textExecutor = visionPack.executors()[0]
    let barcodeExecutor = visionPack.executors()[1]
    let textResult = try await textExecutor.execute(
        call: ToolCall(name: "vision.recognizeText", arguments: [
            "path": "scan.png",
            "languages": ["en-US", "ko-KR"],
        ]),
        context: context
    )
    #expect(textResult.output.objectValue?["observations"]?.arrayValue?.count == 1)
    #expect((await visionService.lastTextPath)?.lastPathComponent == "scan.png")
    #expect(await visionService.lastLanguages == ["en-US", "ko-KR"])

    _ = try await barcodeExecutor.execute(
        call: ToolCall(name: "vision.detectBarcodes", arguments: ["path": "scan.png"]),
        context: context
    )
    #expect((await visionService.lastBarcodePath)?.lastPathComponent == "scan.png")

    await #expect(throws: AgentError.self) {
        _ = try await textExecutor.execute(
            call: ToolCall(name: "vision.recognizeText", arguments: ["path": "../outside.png"]),
            context: context
        )
    }

    let speechService = SpeechServiceStub()
    let speechPack = try SpeechTranscriptionToolPack(
        service: speechService,
        maximumInputBytes: 4,
        defaultLocaleIdentifier: "en-US"
    )
    let speechExecutor = try #require(speechPack.executors().first)
    let speechResult = try await speechExecutor.execute(
        call: ToolCall(name: "speech.transcribeAudio", arguments: ["path": "note.m4a"]),
        context: context
    )
    #expect(speechResult.output.objectValue?["text"]?.stringValue == "hello")
    #expect(speechService.lastPath?.lastPathComponent == "note.m4a")
    #expect(speechService.lastLocaleIdentifier == "en-US")
    #expect(speechService.lastRecognitionMode == .onDeviceOnly)
}

@Test @MainActor
func mapsAndNFCConstrainLocationAndInteractionSurfaces() async throws {
    let root = makeToolPackTempRoot()
    let mapService = MapServiceStub()
    let mapPack = try MapSearchToolPack(service: mapService, maximumResults: 2)
    let mapExecutor = try #require(mapPack.executors().first)
    let mapResult = try await mapExecutor.execute(
        call: ToolCall(name: "maps.search", arguments: [
            "query": "coffee",
            "latitude": 37.5665,
            "longitude": 126.9780,
            "latitudeDelta": 0.1,
            "longitudeDelta": 0.1,
        ]),
        context: noopContext(root: root)
    )
    #expect(mapResult.output.objectValue?["results"]?.arrayValue?.count == 1)
    #expect((await mapService.lastRequest)?.region?.latitude == 37.5665)
    #expect(await mapService.lastMaximumResults == 2)

    await #expect(throws: AgentError.self) {
        _ = try await mapExecutor.execute(
            call: ToolCall(name: "maps.search", arguments: ["query": "coffee", "latitude": 1]),
            context: noopContext(root: root)
        )
    }

    let nfcService = NFCServiceStub()
    let nfcPack = try NFCNDEFReaderToolPack(service: nfcService)
    let nfcExecutor = try #require(nfcPack.executors().first)
    let nfcResult = try await nfcExecutor.execute(
        call: ToolCall(name: "nfc.readNDEF", arguments: [:]),
        context: noopContext(root: root)
    )
    #expect(nfcResult.output.objectValue?["records"]?.arrayValue?.count == 1)
    #expect(nfcService.invocationCount == 1)

    await #expect(throws: AgentError.self) {
        _ = try await nfcExecutor.execute(
            call: ToolCall(name: "nfc.readNDEF", arguments: ["rawCommand": "forbidden"]),
            context: noopContext(root: root)
        )
    }
}

@Test @MainActor
func visionAndMapPacksRejectProviderOverflowInsteadOfTruncating() async throws {
    struct OverflowVisionService: VisionAnalysisToolService {
        func recognizeText(
            in imageURL: URL,
            languages: [String],
            maximumResults: Int
        ) async throws -> [VisionTextObservation] {
            (0..<2).map { index in
                VisionTextObservation(
                    text: "line-\(index)",
                    confidence: 1,
                    boundingBox: VisionNormalizedRectangle(x: 0, y: 0, width: 1, height: 1)
                )
            }
        }

        func detectBarcodes(
            in imageURL: URL,
            maximumResults: Int
        ) async throws -> [VisionBarcodeObservation] {
            []
        }
    }

    struct OverflowMapService: MapSearchToolService {
        func search(
            _ request: MapSearchRequest,
            maximumResults: Int
        ) async throws -> [MapSearchResult] {
            (0..<2).map { index in
                MapSearchResult(
                    name: "Place \(index)",
                    formattedAddress: nil,
                    latitude: 0,
                    longitude: 0,
                    phoneNumber: nil,
                    website: nil
                )
            }
        }
    }

    let root = makeToolPackTempRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data([0]).write(to: root.appendingPathComponent("scan.png"))
    let context = noopContext(root: root)

    let vision = try VisionAnalysisToolPack(
        service: OverflowVisionService(),
        maximumResults: 1
    )
    await #expect(throws: AgentError.self) {
        _ = try await vision.executors()[0].execute(
            call: ToolCall(name: "vision.recognizeText", arguments: ["path": "scan.png"]),
            context: context
        )
    }

    let maps = try MapSearchToolPack(service: OverflowMapService(), maximumResults: 1)
    await #expect(throws: AgentError.self) {
        _ = try await maps.executors()[0].execute(
            call: ToolCall(name: "maps.search", arguments: ["query": "coffee"]),
            context: context
        )
    }
}

private actor PhotoServiceStub: PhotoLibraryToolService {
    private(set) var lastRequest: PhotoAssetListRequest?

    func listAssets(_ request: PhotoAssetListRequest) async throws -> PhotoAssetListResult {
        lastRequest = request
        return PhotoAssetListResult(
            accessScope: .limited,
            assets: [
                PhotoAssetRecord(
                    mediaKind: .image,
                    creationDate: nil,
                    modificationDate: nil,
                    pixelWidth: 100,
                    pixelHeight: 200,
                    durationSeconds: nil
                ),
            ],
            nextCursor: "photos-page-2"
        )
    }
}

private actor HealthServiceStub: HealthSummaryToolService {
    private(set) var lastQuery: HealthQuantityQuery?

    func aggregate(_ query: HealthQuantityQuery) async throws -> HealthQuantitySummary {
        lastQuery = query
        return HealthQuantitySummary(
            metric: query.metric,
            startDate: query.startDate,
            endDate: query.endDate,
            value: 42,
            unit: "count"
        )
    }
}

private actor VisionServiceStub: VisionAnalysisToolService {
    private(set) var lastTextPath: URL?
    private(set) var lastBarcodePath: URL?
    private(set) var lastLanguages: [String] = []

    func recognizeText(in imageURL: URL, languages: [String], maximumResults: Int) async throws -> [VisionTextObservation] {
        lastTextPath = imageURL
        lastLanguages = languages
        return [VisionTextObservation(
            text: "receipt",
            confidence: 0.9,
            boundingBox: VisionNormalizedRectangle(x: 0, y: 0, width: 1, height: 1)
        )]
    }

    func detectBarcodes(in imageURL: URL, maximumResults: Int) async throws -> [VisionBarcodeObservation] {
        lastBarcodePath = imageURL
        return []
    }
}

@MainActor
private final class SpeechServiceStub: SpeechTranscriptionToolService {
    private(set) var lastPath: URL?
    private(set) var lastLocaleIdentifier: String?
    private(set) var lastRecognitionMode: SpeechRecognitionMode?

    func transcribe(
        audioURL: URL,
        localeIdentifier: String,
        recognitionMode: SpeechRecognitionMode
    ) async throws -> SpeechTranscription {
        lastPath = audioURL
        lastLocaleIdentifier = localeIdentifier
        lastRecognitionMode = recognitionMode
        return SpeechTranscription(text: "hello", localeIdentifier: localeIdentifier)
    }
}

private actor MapServiceStub: MapSearchToolService {
    private(set) var lastRequest: MapSearchRequest?
    private(set) var lastMaximumResults: Int?

    func search(_ request: MapSearchRequest, maximumResults: Int) async throws -> [MapSearchResult] {
        lastRequest = request
        lastMaximumResults = maximumResults
        return [MapSearchResult(
            name: "Coffee",
            formattedAddress: "Seoul",
            latitude: 37.5665,
            longitude: 126.978,
            phoneNumber: nil,
            website: nil
        )]
    }
}

@MainActor
private final class NFCServiceStub: NFCNDEFReadingToolService {
    private(set) var invocationCount = 0

    func readSingleMessage() async throws -> [NFCNDEFRecord] {
        invocationCount += 1
        return [NFCNDEFRecord(
            typeNameFormat: 1,
            type: "U",
            identifierBase64: "",
            payloadBase64: "AQ==",
            wellKnownURI: "https://example.com"
        )]
    }
}
