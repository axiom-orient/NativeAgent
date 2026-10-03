import NativeAgentDomain
import Foundation

public enum PhotoLibraryMediaKind: String, CaseIterable, Codable, Sendable {
    case image
    case video
}

public enum PhotoLibraryAccessScope: String, Codable, Sendable {
    case full
    case limited
}

public struct PhotoAssetListRequest: Sendable, Equatable {
    static let maximumPageSize = 100
    static let maximumCursorBytes = 4_096

    public let mediaKind: PhotoLibraryMediaKind?
    public let createdAfter: Date?
    public let createdBefore: Date?
    public let limit: Int
    public let cursor: String?

    public init(
        mediaKind: PhotoLibraryMediaKind? = nil,
        createdAfter: Date? = nil,
        createdBefore: Date? = nil,
        limit: Int,
        cursor: String? = nil
    ) throws {
        guard (1...Self.maximumPageSize).contains(limit) else {
            throw AgentError.invalidToolCall("photos.listAssets page size must be between 1 and 100.")
        }
        if let createdAfter, let createdBefore, createdAfter >= createdBefore {
            throw AgentError.invalidToolCall("photos.listAssets createdAfter must be earlier than createdBefore.")
        }
        self.mediaKind = mediaKind
        self.createdAfter = createdAfter
        self.createdBefore = createdBefore
        self.limit = limit
        if let cursor {
            guard cursor.isEmpty == false,
                  cursor.utf8.count <= Self.maximumCursorBytes else {
                throw AgentError.invalidToolCall("photos.listAssets cursor is invalid.")
            }
        }
        self.cursor = cursor
    }

    init(arguments: JSONValue) throws {
        let object = try requiredObject(arguments, toolName: "photos.listAssets")
        try rejectUnknownKeys(
            object,
            allowed: ["mediaKind", "createdAfter", "createdBefore", "limit", "cursor"],
            toolName: "photos.listAssets"
        )

        let mediaKind: PhotoLibraryMediaKind?
        if let rawKind = object["mediaKind"]?.stringValue {
            guard let parsed = PhotoLibraryMediaKind(rawValue: rawKind) else {
                throw AgentError.invalidToolCall("photos.listAssets mediaKind must be image or video.")
            }
            mediaKind = parsed
        } else if object["mediaKind"] != nil {
            throw AgentError.invalidToolCall("photos.listAssets mediaKind must be a string.")
        } else {
            mediaKind = nil
        }

        let createdAfter = try optionalISO8601Date(object["createdAfter"], field: "createdAfter", toolName: "photos.listAssets")
        let createdBefore = try optionalISO8601Date(object["createdBefore"], field: "createdBefore", toolName: "photos.listAssets")
        let limit = try optionalBoundedInt(object["limit"], field: "limit", defaultValue: 25, range: 1...100, toolName: "photos.listAssets")
        let cursor: String?
        if let value = object["cursor"] {
            guard let parsed = value.stringValue else {
                throw AgentError.invalidToolCall("photos.listAssets cursor must be a string.")
            }
            cursor = parsed
        } else {
            cursor = nil
        }
        try self.init(
            mediaKind: mediaKind,
            createdAfter: createdAfter,
            createdBefore: createdBefore,
            limit: limit,
            cursor: cursor
        )
    }
}

public struct PhotoAssetRecord: Codable, Sendable, Equatable {
    public let mediaKind: PhotoLibraryMediaKind
    public let creationDate: Date?
    public let modificationDate: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let durationSeconds: Double?

    public init(
        mediaKind: PhotoLibraryMediaKind,
        creationDate: Date?,
        modificationDate: Date?,
        pixelWidth: Int,
        pixelHeight: Int,
        durationSeconds: Double?
    ) {
        self.mediaKind = mediaKind
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationSeconds = durationSeconds
    }
}

public struct PhotoAssetListResult: Sendable, Equatable {
    public let accessScope: PhotoLibraryAccessScope
    public let assets: [PhotoAssetRecord]
    public let nextCursor: String?

    public init(
        accessScope: PhotoLibraryAccessScope,
        assets: [PhotoAssetRecord],
        nextCursor: String? = nil
    ) {
        self.accessScope = accessScope
        self.assets = assets
        self.nextCursor = nextCursor
    }
}

/// Read-only metadata boundary for assets the user has authorized the host app
/// to view. It neither exports image bytes nor performs library mutations.
public protocol PhotoLibraryToolService: Sendable {
    /// The provider owns cursor encoding and must bind it to the request's
    /// media/date filters. `limit` is a page size, not a library-wide cap.
    func listAssets(_ request: PhotoAssetListRequest) async throws -> PhotoAssetListResult
}

public struct PhotoLibraryToolPack: ToolPack {
    public let packID: String
    private let service: any PhotoLibraryToolService

    public init(
        service: any PhotoLibraryToolService,
        packID: String = "toolpack.photos"
    ) throws {
        try validatePackID(packID)
        self.service = service
        self.packID = packID
    }

    public func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: definition) { call, _ in
                let request = try PhotoAssetListRequest(arguments: call.arguments)
                let result = try await service.listAssets(request)
                guard result.assets.count <= request.limit else {
                    throw AgentError.invariantViolation("Photos provider returned more assets than requested.")
                }
                if let nextCursor = result.nextCursor {
                    guard nextCursor.isEmpty == false,
                          nextCursor.utf8.count <= PhotoAssetListRequest.maximumCursorBytes else {
                        throw AgentError.invariantViolation("Photos provider returned an invalid cursor.")
                    }
                }
                return ToolResult(
                    callID: call.id,
                    toolName: call.name,
                    output: .object([
                        "accessScope": .string(result.accessScope.rawValue),
                        "assets": try JSONValue.encode(result.assets),
                        "nextCursor": result.nextCursor.map(JSONValue.string) ?? .null,
                        "hasMore": .bool(result.nextCursor != nil),
                    ]),
                    metadata: ["assetCount": .integer(Int64(result.assets.count))]
                )
            },
        ]
    }

    private var definition: ToolDefinition {
        ToolDefinition(
            name: "photos.listAssets",
            description: "List read-only photo metadata in bounded pages across the authorized library. Pass nextCursor with the same filters to continue. It never returns image bytes or changes the library.",
            capabilityID: .photos,
            inputSchema: ToolSchema.object(
                properties: [
                    "mediaKind": ToolSchema.string(description: "Optional asset kind: image or video."),
                    "createdAfter": ToolSchema.string(description: "Optional inclusive ISO-8601 creation time.", format: "date-time"),
                    "createdBefore": ToolSchema.string(description: "Optional exclusive ISO-8601 creation time.", format: "date-time"),
                    "limit": ToolSchema.integer(description: "Maximum assets in this page. Defaults to 25.", minimum: 1, maximum: PhotoAssetListRequest.maximumPageSize),
                    "cursor": ToolSchema.string(description: "Opaque nextCursor from the preceding page for the same filters.", minLength: 1, maxLength: PhotoAssetListRequest.maximumCursorBytes),
                ]
            ),
            approvalPolicy: .requireApproval,
            effect: .readOnly,
            metadata: ["sensitiveData": .bool(true)]
        )
    }
}

#if canImport(Photos)
import Photos

@available(iOS 17, *)
public actor PHPhotoLibraryToolService: PhotoLibraryToolService {
    public init() {}

    public func listAssets(_ request: PhotoAssetListRequest) async throws -> PhotoAssetListResult {
        try requireHostUsageDescription("NSPhotoLibraryUsageDescription", capability: "Photos access")
        let accessScope = try await requestReadAccess()
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let predicate = predicate(for: request) {
            options.predicate = predicate
        }

        let assets: PHFetchResult<PHAsset>
        if let mediaKind = request.mediaKind {
            assets = PHAsset.fetchAssets(with: phMediaType(for: mediaKind), options: options)
        } else {
            assets = PHAsset.fetchAssets(with: options)
        }

        let offset = try decodeCursor(request.cursor, request: request)
        guard offset <= assets.count else {
            throw AgentError.invalidToolCall("Photos cursor no longer matches the current library view.")
        }
        let endIndex = min(offset + request.limit, assets.count)
        var records: [PhotoAssetRecord] = []
        records.reserveCapacity(endIndex - offset)
        for index in offset..<endIndex {
            let asset = assets.object(at: index)
            guard let mediaKind = Self.mediaKind(for: asset.mediaType) else { continue }
            records.append(
                PhotoAssetRecord(
                    mediaKind: mediaKind,
                    creationDate: asset.creationDate,
                    modificationDate: asset.modificationDate,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    durationSeconds: asset.mediaType == .video ? asset.duration : nil
                )
            )
        }
        return PhotoAssetListResult(
            accessScope: accessScope,
            assets: records,
            nextCursor: endIndex < assets.count ? try encodeCursor(offset: endIndex, request: request) : nil
        )
    }

    private struct PhotosCursor: Codable {
        let version: Int
        let mediaKind: PhotoLibraryMediaKind?
        let createdAfter: Date?
        let createdBefore: Date?
        let offset: Int
    }

    private func decodeCursor(_ cursor: String?, request: PhotoAssetListRequest) throws -> Int {
        guard let cursor else { return 0 }
        guard cursor.utf8.count <= PhotoAssetListRequest.maximumCursorBytes,
              let data = Data(base64Encoded: cursor),
              let value = try? JSONDecoder().decode(PhotosCursor.self, from: data),
              value.version == 1,
              value.mediaKind == request.mediaKind,
              value.createdAfter == request.createdAfter,
              value.createdBefore == request.createdBefore,
              value.offset >= 0 else {
            throw AgentError.invalidToolCall("Photos cursor does not match these filters.")
        }
        return value.offset
    }

    private func encodeCursor(offset: Int, request: PhotoAssetListRequest) throws -> String {
        let value = PhotosCursor(
            version: 1,
            mediaKind: request.mediaKind,
            createdAfter: request.createdAfter,
            createdBefore: request.createdBefore,
            offset: offset
        )
        let cursor = try JSONEncoder().encode(value).base64EncodedString()
        guard cursor.utf8.count <= PhotoAssetListRequest.maximumCursorBytes else {
            throw AgentError.invariantViolation("Photos cursor exceeded its safety bound.")
        }
        return cursor
    }

    private func requestReadAccess() async throws -> PhotoLibraryAccessScope {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let resolvedStatus: PHAuthorizationStatus
        if status == .notDetermined {
            resolvedStatus = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { result in
                    continuation.resume(returning: result)
                }
            }
        } else {
            resolvedStatus = status
        }

        switch resolvedStatus {
        case .authorized:
            return .full
        case .limited:
            return .limited
        case .denied, .restricted, .notDetermined:
            throw AgentError.accessDenied("Photos access was not granted.")
        @unknown default:
            throw AgentError.accessDenied("Photos access returned an unsupported authorization state.")
        }
    }

    private func predicate(for request: PhotoAssetListRequest) -> NSPredicate? {
        var predicates: [NSPredicate] = []
        if request.mediaKind == nil {
            predicates.append(NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue
            ))
        }
        if let createdAfter = request.createdAfter {
            predicates.append(NSPredicate(format: "creationDate >= %@", createdAfter as NSDate))
        }
        if let createdBefore = request.createdBefore {
            predicates.append(NSPredicate(format: "creationDate < %@", createdBefore as NSDate))
        }
        guard predicates.isEmpty == false else { return nil }
        return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }

    private func phMediaType(for kind: PhotoLibraryMediaKind) -> PHAssetMediaType {
        switch kind {
        case .image: .image
        case .video: .video
        }
    }

    private static func mediaKind(for type: PHAssetMediaType) -> PhotoLibraryMediaKind? {
        switch type {
        case .image: .image
        case .video: .video
        default: nil
        }
    }
}
#endif
