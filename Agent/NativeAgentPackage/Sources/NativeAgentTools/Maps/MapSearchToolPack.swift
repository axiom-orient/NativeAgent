import NativeAgentDomain
import Foundation

public struct MapSearchRegion: Codable, Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let latitudeDelta: Double
    public let longitudeDelta: Double

    public init(
        latitude: Double,
        longitude: Double,
        latitudeDelta: Double,
        longitudeDelta: Double
    ) throws {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw AgentError.invalidToolCall("Map search coordinates are outside valid latitude/longitude bounds.")
        }
        guard latitudeDelta > 0, latitudeDelta <= 180,
              longitudeDelta > 0, longitudeDelta <= 360 else {
            throw AgentError.invalidToolCall("Map search region deltas are outside valid bounds.")
        }
        self.latitude = latitude
        self.longitude = longitude
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }
}

public struct MapSearchRequest: Sendable, Equatable {
    public let query: String
    public let region: MapSearchRegion?

    public init(query: String, region: MapSearchRegion? = nil) throws {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...512).contains(query.unicodeScalars.count) else {
            throw AgentError.invalidToolCall("maps.search query must contain 1 to 512 Unicode scalars.")
        }
        self.query = query
        self.region = region
    }

    init(arguments: JSONValue) throws {
        let object = try requiredObject(arguments, toolName: "maps.search")
        try rejectUnknownKeys(
            object,
            allowed: ["query", "latitude", "longitude", "latitudeDelta", "longitudeDelta"],
            toolName: "maps.search"
        )
        guard let query = object["query"]?.stringValue else {
            throw AgentError.invalidToolCall("maps.search requires a query string.")
        }

        let regionKeys = ["latitude", "longitude", "latitudeDelta", "longitudeDelta"]
        let suppliedRegionKeys = regionKeys.filter { object[$0] != nil }
        let region: MapSearchRegion?
        if suppliedRegionKeys.isEmpty {
            region = nil
        } else {
            guard suppliedRegionKeys.count == regionKeys.count,
                  let latitude = object["latitude"]?.numberValue,
                  let longitude = object["longitude"]?.numberValue,
                  let latitudeDelta = object["latitudeDelta"]?.numberValue,
                  let longitudeDelta = object["longitudeDelta"]?.numberValue else {
                throw AgentError.invalidToolCall("maps.search region requires latitude, longitude, latitudeDelta, and longitudeDelta together.")
            }
            region = try MapSearchRegion(
                latitude: latitude,
                longitude: longitude,
                latitudeDelta: latitudeDelta,
                longitudeDelta: longitudeDelta
            )
        }
        try self.init(query: query, region: region)
    }
}

public struct MapSearchResult: Codable, Sendable, Equatable {
    public let name: String?
    public let formattedAddress: String?
    public let latitude: Double
    public let longitude: Double
    public let phoneNumber: String?
    public let website: String?

    public init(
        name: String?,
        formattedAddress: String?,
        latitude: Double,
        longitude: Double,
        phoneNumber: String?,
        website: String?
    ) {
        self.name = name
        self.formattedAddress = formattedAddress
        self.latitude = latitude
        self.longitude = longitude
        self.phoneNumber = phoneNumber
        self.website = website
    }
}

/// Search only: this interface never reads the current device location, opens
/// Maps, or requests routes.
public protocol MapSearchToolService: Sendable {
    func search(_ request: MapSearchRequest, maximumResults: Int) async throws -> [MapSearchResult]
}

public struct MapSearchToolPack: ToolPack {
    public let packID: String
    private let service: any MapSearchToolService
    private let maximumResults: Int

    public init(
        service: any MapSearchToolService,
        maximumResults: Int = 50,
        packID: String = "toolpack.maps"
    ) throws {
        try validatePackID(packID)
        guard (1...50).contains(maximumResults) else {
            throw AgentError.invalidConfiguration("Map maximum results must be between 1 and 50.")
        }
        self.service = service
        self.maximumResults = maximumResults
        self.packID = packID
    }

    public func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: definition) { call, _ in
                let results = try await service.search(
                    try MapSearchRequest(arguments: call.arguments),
                    maximumResults: maximumResults
                )
                guard results.count <= maximumResults else {
                    throw AgentError.invariantViolation(
                        "Map provider returned more results than requested."
                    )
                }
                return ToolResult(
                    callID: call.id,
                    toolName: call.name,
                    output: .object(["results": try JSONValue.encode(results)])
                )
            },
        ]
    }

    private var definition: ToolDefinition {
        ToolDefinition(
            name: "maps.search",
            description: "Search public places or addresses with an explicit query and optional caller-supplied region. This tool never reads device location, opens Maps, or requests routes.",
            capabilityID: .maps,
            inputSchema: ToolSchema.object(
                properties: [
                    "query": ToolSchema.string(description: "Place, address, or category query.", minLength: 1, maxLength: 512),
                    "latitude": ToolSchema.number(description: "Optional search-region center latitude.", minimum: -90, maximum: 90),
                    "longitude": ToolSchema.number(description: "Optional search-region center longitude.", minimum: -180, maximum: 180),
                    "latitudeDelta": ToolSchema.number(description: "Optional positive latitude span.", minimum: 0.000001, maximum: 180),
                    "longitudeDelta": ToolSchema.number(description: "Optional positive longitude span.", minimum: 0.000001, maximum: 360),
                ],
                required: ["query"]
            ),
            approvalPolicy: .requireApproval,
            effect: .readOnly,
            metadata: ["networkAccess": .bool(true), "locationAccess": .bool(false)]
        )
    }
}

#if canImport(MapKit)
@preconcurrency import MapKit

@available(iOS 26, macOS 26, *)
public actor MapKitSearchToolService: MapSearchToolService {
    private var activeSearch: MKLocalSearch?

    public init() {}

    public func search(_ request: MapSearchRequest, maximumResults: Int) async throws -> [MapSearchResult] {
        guard activeSearch == nil else {
            throw AgentError.sessionBusy("A map search is already active.")
        }
        let searchRequest = MKLocalSearch.Request()
        searchRequest.naturalLanguageQuery = request.query
        if let region = request.region {
            searchRequest.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: region.latitude, longitude: region.longitude),
                span: MKCoordinateSpan(latitudeDelta: region.latitudeDelta, longitudeDelta: region.longitudeDelta)
            )
        }
        let search = MKLocalSearch(request: searchRequest)
        activeSearch = search
        defer {
            activeSearch = nil
            search.cancel()
        }
        let response = try await search.start()
        try Task.checkCancellation()
        guard response.mapItems.count <= maximumResults else {
            throw AgentError.budgetExceeded(
                "Map search returned more than \(maximumResults) results; refine the query or region."
            )
        }
        return response.mapItems.map { item in
            MapSearchResult(
                name: item.name,
                formattedAddress: item.address?.fullAddress,
                latitude: item.location.coordinate.latitude,
                longitude: item.location.coordinate.longitude,
                phoneNumber: item.phoneNumber,
                website: item.url?.absoluteString
            )
        }
    }
}
#endif
