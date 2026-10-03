import NativeAgentDomain
import Foundation

public enum HealthQuantityMetric: String, CaseIterable, Codable, Sendable, Hashable {
    case stepCount
    case activeEnergyBurned
    case walkingRunningDistance
}

public struct HealthQuantityQuery: Sendable, Equatable {
    public let metric: HealthQuantityMetric
    public let startDate: Date
    public let endDate: Date

    public init(metric: HealthQuantityMetric, startDate: Date, endDate: Date) throws {
        guard startDate < endDate else {
            throw AgentError.invalidToolCall("health.aggregateQuantity startDate must be earlier than endDate.")
        }
        self.metric = metric
        self.startDate = startDate
        self.endDate = endDate
    }

    init(arguments: JSONValue) throws {
        let object = try requiredObject(arguments, toolName: "health.aggregateQuantity")
        try rejectUnknownKeys(
            object,
            allowed: ["metric", "startDate", "endDate"],
            toolName: "health.aggregateQuantity"
        )
        guard let metricValue = object["metric"]?.stringValue,
              let metric = HealthQuantityMetric(rawValue: metricValue) else {
            throw AgentError.invalidToolCall("health.aggregateQuantity metric is unsupported.")
        }
        guard let startValue = object["startDate"]?.stringValue,
              let endValue = object["endDate"]?.stringValue else {
            throw AgentError.invalidToolCall("health.aggregateQuantity requires ISO-8601 startDate and endDate.")
        }
        try self.init(
            metric: metric,
            startDate: parseNativeAgentISO8601Date(startValue),
            endDate: parseNativeAgentISO8601Date(endValue)
        )
    }
}

public struct HealthQuantitySummary: Codable, Sendable, Equatable {
    public let metric: HealthQuantityMetric
    public let startDate: Date
    public let endDate: Date
    public let value: Double
    public let unit: String
    /// HealthKit intentionally does not reveal whether a person denied a
    /// particular read type. Empty or partial results must not be presented as
    /// proof that no health data exists.
    public let dataMayBeIncomplete: Bool

    public init(
        metric: HealthQuantityMetric,
        startDate: Date,
        endDate: Date,
        value: Double,
        unit: String,
        dataMayBeIncomplete: Bool = true
    ) {
        self.metric = metric
        self.startDate = startDate
        self.endDate = endDate
        self.value = value
        self.unit = unit
        self.dataMayBeIncomplete = dataMayBeIncomplete
    }
}

/// Read-only quantity aggregation. The host selects the small set of Health
/// types it is willing to request before the agent is composed.
public protocol HealthSummaryToolService: Sendable {
    func aggregate(_ query: HealthQuantityQuery) async throws -> HealthQuantitySummary
}

public struct HealthSummaryToolPack: ToolPack {
    public let packID: String
    private let service: any HealthSummaryToolService
    private let allowedMetrics: Set<HealthQuantityMetric>
    private let maximumQueryInterval: TimeInterval

    public init(
        service: any HealthSummaryToolService,
        allowedMetrics: Set<HealthQuantityMetric> = [.stepCount],
        maximumQueryInterval: TimeInterval = 31 * 24 * 60 * 60,
        packID: String = "toolpack.health"
    ) throws {
        try validatePackID(packID)
        guard allowedMetrics.isEmpty == false else {
            throw AgentError.invalidConfiguration("Health tool pack requires at least one allowed metric.")
        }
        guard maximumQueryInterval > 0 else {
            throw AgentError.invalidConfiguration("Health maximum query interval must be positive.")
        }
        self.service = service
        self.allowedMetrics = allowedMetrics
        self.maximumQueryInterval = maximumQueryInterval
        self.packID = packID
    }

    public func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: definition) { call, _ in
                let query = try HealthQuantityQuery(arguments: call.arguments)
                guard allowedMetrics.contains(query.metric) else {
                    throw AgentError.accessDenied("Health metric \(query.metric.rawValue) is not enabled by the host.")
                }
                guard query.endDate.timeIntervalSince(query.startDate) <= maximumQueryInterval else {
                    throw AgentError.budgetExceeded("Health query exceeds the host-configured time range.")
                }
                let summary = try await service.aggregate(query)
                return ToolResult(
                    callID: call.id,
                    toolName: call.name,
                    output: try JSONValue.encode(summary),
                    metadata: ["sensitiveData": .bool(true)]
                )
            },
        ]
    }

    private var definition: ToolDefinition {
        ToolDefinition(
            name: "health.aggregateQuantity",
            description: "Read an approved HealthKit quantity total for a bounded date range. Empty values can reflect privacy-limited access and do not prove that no data exists.",
            capabilityID: .health,
            inputSchema: ToolSchema.object(
                properties: [
                    "metric": ToolSchema.string(description: "One host-enabled metric: stepCount, activeEnergyBurned, or walkingRunningDistance."),
                    "startDate": ToolSchema.string(description: "Inclusive ISO-8601 start date-time.", format: "date-time"),
                    "endDate": ToolSchema.string(description: "Exclusive ISO-8601 end date-time.", format: "date-time"),
                ],
                required: ["metric", "startDate", "endDate"]
            ),
            approvalPolicy: .requireApproval,
            effect: .readOnly,
            metadata: ["sensitiveData": .bool(true)]
        )
    }
}

#if canImport(HealthKit)
import HealthKit

@available(iOS 17, *)
public actor HealthKitSummaryToolService: HealthSummaryToolService {
    private let store: HKHealthStore
    private let allowedMetrics: Set<HealthQuantityMetric>

    public init(
        allowedMetrics: Set<HealthQuantityMetric> = [.stepCount]
    ) throws {
        guard allowedMetrics.isEmpty == false else {
            throw AgentError.invalidConfiguration("HealthKit service requires at least one allowed metric.")
        }
        self.store = HKHealthStore()
        self.allowedMetrics = allowedMetrics
    }

    public func aggregate(_ query: HealthQuantityQuery) async throws -> HealthQuantitySummary {
        guard allowedMetrics.contains(query.metric) else {
            throw AgentError.accessDenied("Health metric \(query.metric.rawValue) is not enabled by the host.")
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            throw AgentError.unsupportedSurface("HealthKit is unavailable on this device.")
        }

        let quantityType = try quantityType(for: query.metric)
        try await requestReadAuthorization(for: quantityType)
        try Task.checkCancellation()

        let predicate = HKQuery.predicateForSamples(
            withStart: query.startDate,
            end: query.endDate,
            options: .strictStartDate
        )
        let statistics = try await store.statistics(
            for: quantityType,
            predicate: predicate,
            options: .cumulativeSum
        )
        let unit = unit(for: query.metric)
        let value = statistics.sumQuantity()?.doubleValue(for: unit) ?? 0
        return HealthQuantitySummary(
            metric: query.metric,
            startDate: query.startDate,
            endDate: query.endDate,
            value: value,
            unit: unit.unitString,
            dataMayBeIncomplete: true
        )
    }

    private func requestReadAuthorization(for type: HKQuantityType) async throws {
        try requireHostUsageDescription("NSHealthShareUsageDescription", capability: "HealthKit read access")
        try await store.requestAuthorization(toShare: [], read: [type])
    }

    private func quantityType(for metric: HealthQuantityMetric) throws -> HKQuantityType {
        let identifier: HKQuantityTypeIdentifier
        switch metric {
        case .stepCount: identifier = .stepCount
        case .activeEnergyBurned: identifier = .activeEnergyBurned
        case .walkingRunningDistance: identifier = .distanceWalkingRunning
        }
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
            throw AgentError.unsupportedSurface("HealthKit does not support \(metric.rawValue) on this platform.")
        }
        return type
    }

    private func unit(for metric: HealthQuantityMetric) -> HKUnit {
        switch metric {
        case .stepCount: .count()
        case .activeEnergyBurned: .kilocalorie()
        case .walkingRunningDistance: .meter()
        }
    }
}

private extension HKHealthStore {
    func statistics(
        for type: HKQuantityType,
        predicate: NSPredicate,
        options: HKStatisticsOptions
    ) async throws -> HKStatistics {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: options
            ) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let statistics {
                    continuation.resume(returning: statistics)
                } else {
                    continuation.resume(throwing: AgentError.modelFailure("HealthKit returned no statistics result."))
                }
            }
            execute(query)
        }
    }
}
#endif
