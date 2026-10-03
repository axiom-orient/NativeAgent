import Foundation
import NativeAgentDomain

public struct CalendarToolPack: ToolPack {
    public let packID = "toolpack.calendar"
    private let service: any CalendarToolService

    public init(service: any CalendarToolService) {
        self.service = service
    }

    public func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: listDefinition) { call, _ in
                let request = try CalendarListEventsRequest(arguments: call.arguments)
                let page = try await service.listEvents(
                    startDate: request.startDate,
                    endDate: request.endDate,
                    limit: request.limit,
                    cursor: request.cursor
                )
                guard page.events.count <= request.limit else {
                    throw AgentError.invariantViolation(
                        "Calendar provider returned more events than requested."
                    )
                }
                if let nextCursor = page.nextCursor {
                    guard nextCursor.isEmpty == false,
                          nextCursor.utf8.count <= CalendarListPolicy.maximumCursorBytes else {
                        throw AgentError.invariantViolation("Calendar provider returned an invalid cursor.")
                    }
                }
                return ToolResult(
                    callID: call.id,
                    toolName: call.name,
                    output: calendarEventsOutput(page),
                    metadata: ["resultCount": .integer(Int64(page.events.count))]
                )
            },
            ClosureToolExecutor(definition: createDefinition) { call, _ in
                let request = try calendarPreflight(operation: "calendar.createEvent.preflight") {
                    try CalendarCreateEventRequest(arguments: call.arguments)
                }
                let event = try await service.createEvent(request.draft)
                return ToolResult(
                    callID: call.id,
                    toolName: call.name,
                    output: calendarEventOutput(event),
                    metadata: [
                        "identifier": .string(event.identifier),
                        "verification": .string("provider_result")
                    ]
                )
            },
            ClosureToolExecutor(definition: updateDefinition) { call, _ in
                let request = try calendarPreflight(operation: "calendar.updateEvent.preflight") {
                    try CalendarUpdateEventRequest(arguments: call.arguments)
                }
                try await verifyCalendarPrecondition(
                    service: service,
                    operation: "calendar.updateEvent.preflight",
                    identifier: request.identifier,
                    expectedRevision: request.expectedRevision
                )
                let event = try await service.updateEvent(
                    identifier: request.identifier,
                    draft: request.draft
                )
                let verified = try await verifyCalendarUpdateIfSupported(
                    service: service,
                    event: event,
                    draft: request.draft
                )
                return ToolResult(
                    callID: call.id,
                    toolName: call.name,
                    output: calendarEventOutput(verified ?? event),
                    metadata: [
                        "identifier": .string(event.identifier),
                        "verification": .string(verified == nil ? "not_supported" : "read_back")
                    ]
                )
            },
            ClosureToolExecutor(definition: deleteDefinition) { call, _ in
                let request = try calendarPreflight(operation: "calendar.deleteEvent.preflight") {
                    try CalendarDeleteEventRequest(arguments: call.arguments)
                }
                try await verifyCalendarPrecondition(
                    service: service,
                    operation: "calendar.deleteEvent.preflight",
                    identifier: request.identifier,
                    expectedRevision: request.expectedRevision
                )
                try await service.deleteEvent(identifier: request.identifier)
                let verifiedAbsent = try await verifyCalendarDeleteIfSupported(
                    service: service,
                    identifier: request.identifier
                )
                return ToolResult(
                    callID: call.id,
                    toolName: call.name,
                    output: .object([
                        "identifier": .string(request.identifier),
                        "deleted": .bool(true),
                        "verifiedAbsent": verifiedAbsent.map(JSONValue.bool) ?? .null
                    ]),
                    metadata: [
                        "identifier": .string(request.identifier),
                        "verification": .string(verifiedAbsent == nil ? "not_supported" : "read_back")
                    ]
                )
            }
        ]
    }

    private var listDefinition: ToolDefinition {
        ToolDefinition(
            name: "calendar.listEvents",
            description: "List calendar events across any valid date range in bounded pages. Pass nextCursor with the same range to continue.",
            capabilityID: .calendar,
            inputSchema: ToolSchema.object(
                properties: [
                    "startDate": ToolSchema.string(
                        description: "ISO-8601 inclusive start date-time.",
                        format: "date-time"
                    ),
                    "endDate": ToolSchema.string(
                        description: "ISO-8601 exclusive end date-time.",
                        format: "date-time"
                    ),
                    "limit": ToolSchema.integer(
                        description: "Maximum events in this page. Defaults to 50.",
                        minimum: 1,
                        maximum: CalendarListPolicy.maximumPageSize
                    ),
                    "cursor": ToolSchema.string(
                        description: "Opaque nextCursor from the preceding page for the same date range.",
                        minLength: 1,
                        maxLength: CalendarListPolicy.maximumCursorBytes
                    ),
                ],
                required: ["startDate", "endDate"]
            ),
            approvalPolicy: .requireApproval,
            effect: .readOnly,
            metadata: ["sensitiveData": .bool(true)]
        )
    }

    private var createDefinition: ToolDefinition {
        mutationDefinition(
            name: "calendar.createEvent",
            description: "Create a calendar event. All-day endDate is exclusive."
        )
    }

    private var updateDefinition: ToolDefinition {
        mutationDefinition(
            name: "calendar.updateEvent",
            description: "Replace an existing calendar event. All-day endDate is exclusive.",
            includesIdentifier: true
        )
    }

    private var deleteDefinition: ToolDefinition {
        ToolDefinition(
            name: "calendar.deleteEvent",
            description: "Delete an existing calendar event by identifier.",
            capabilityID: .calendar,
            inputSchema: ToolSchema.object(
                properties: [
                    "identifier": ToolSchema.string(
                        description: "Stable event identifier returned by calendar.listEvents.",
                        minLength: 1
                    ),
                    "expectedRevision": ToolSchema.string(
                        description: "Optional revision returned by calendar.listEvents. When supplied, deletion fails if the event changed.",
                        minLength: 1,
                        maxLength: 512
                    )
                ],
                required: ["identifier"]
            ),
            approvalPolicy: .requireApproval,
            metadata: ["sensitiveData": .bool(true)]
        )
    }

    private func mutationDefinition(
        name: String,
        description: String,
        includesIdentifier: Bool = false
    ) -> ToolDefinition {
        var properties: [String: JSONValue] = [
            "title": ToolSchema.string(description: "Event title.", minLength: 1),
            "startDate": ToolSchema.string(
                description: "ISO-8601 start date-time.",
                format: "date-time"
            ),
            "endDate": ToolSchema.string(
                description: "ISO-8601 end date-time.",
                format: "date-time"
            ),
            "location": ToolSchema.string(description: "Event location."),
            "notes": ToolSchema.string(description: "Event notes."),
            "isAllDay": ToolSchema.boolean(
                description: "Whether the event spans whole calendar days. Defaults to false."
            )
        ]
        var required = ["title", "startDate", "endDate"]
        if includesIdentifier {
            properties["identifier"] = ToolSchema.string(
                description: "Stable event identifier returned by calendar.listEvents.",
                minLength: 1
            )
            properties["expectedRevision"] = ToolSchema.string(
                description: "Optional revision returned by calendar.listEvents. When supplied, update fails if the event changed.",
                minLength: 1,
                maxLength: 512
            )
            required.insert("identifier", at: 0)
        }
        return ToolDefinition(
            name: name,
            description: description,
            capabilityID: .calendar,
            inputSchema: ToolSchema.object(properties: properties, required: required),
            approvalPolicy: .requireApproval,
            metadata: ["sensitiveData": .bool(true)]
        )
    }
}

private func verifyCalendarPrecondition(
    service: any CalendarToolService,
    operation: String,
    identifier: String,
    expectedRevision: String?
) async throws {
    guard let expectedRevision else { return }
    guard let verifier = service as? any CalendarEventVerificationService else {
        throw ToolPreflightFailure(
            code: .unsupported,
            operation: operation,
            cause: "Calendar expectedRevision requires a service that can inspect the current event.",
            context: ["identifier": identifier]
        )
    }

    let current: CalendarEventRecord?
    do {
        current = try await verifier.event(identifier: identifier)
    } catch is CancellationError {
        throw CancellationError()
    } catch let failure as ToolPreflightFailure {
        throw failure
    } catch let error as AgentError {
        throw ToolPreflightFailure(
            code: error.defaultToolFailureCode,
            operation: operation,
            cause: error.localizedDescription,
            context: ["identifier": identifier]
        )
    } catch {
        throw ToolPreflightFailure(
            code: .temporaryFailure,
            operation: operation,
            cause: error.localizedDescription,
            context: ["identifier": identifier]
        )
    }

    guard let current else {
        throw ToolPreflightFailure(
            code: .conflict,
            operation: operation,
            cause: "Calendar event no longer exists.",
            context: ["identifier": identifier, "expectedRevision": expectedRevision]
        )
    }
    guard let actualRevision = current.revision else {
        throw ToolPreflightFailure(
            code: .unsupported,
            operation: operation,
            cause: "Calendar service did not provide a revision.",
            context: ["identifier": identifier]
        )
    }
    guard actualRevision == expectedRevision else {
        throw ToolPreflightFailure(
            code: .conflict,
            operation: operation,
            cause: "Calendar event changed before mutation.",
            context: [
                "identifier": identifier,
                "expectedRevision": expectedRevision,
                "actualRevision": actualRevision
            ]
        )
    }
}

private func calendarPreflight<T>(
    operation: String,
    _ body: () throws -> T
) throws -> T {
    do {
        return try body()
    } catch let failure as ToolPreflightFailure {
        throw failure
    } catch let error as AgentError {
        throw ToolPreflightFailure(
            code: error.defaultToolFailureCode,
            operation: operation,
            cause: error.localizedDescription
        )
    } catch {
        throw ToolPreflightFailure(
            code: .temporaryFailure,
            operation: operation,
            cause: error.localizedDescription
        )
    }
}

private func verifyCalendarUpdateIfSupported(
    service: any CalendarToolService,
    event: CalendarEventRecord,
    draft: CalendarEventDraft
) async throws -> CalendarEventRecord? {
    guard let verifier = service as? any CalendarEventVerificationService else { return nil }
    guard let observed = try await verifier.event(identifier: event.identifier) else {
        throw EffectFailure.outcomeUnknown(
            operation: "calendar.updateEvent.verify",
            cause: "Updated event cannot be read back.",
            context: ["identifier": event.identifier]
        )
    }
    let expected = draft.normalizedForStorage
    guard observed.title == expected.title,
          observed.startDate == expected.startDate,
          observed.endDate == expected.endDate,
          observed.location == expected.location,
          observed.notes == expected.notes,
          observed.isAllDay == expected.isAllDay else {
        throw EffectFailure.outcomeUnknown(
            operation: "calendar.updateEvent.verify",
            cause: "Read-back event differs from the requested draft.",
            context: ["identifier": event.identifier]
        )
    }
    return observed
}

private func verifyCalendarDeleteIfSupported(
    service: any CalendarToolService,
    identifier: String
) async throws -> Bool? {
    guard let verifier = service as? any CalendarEventVerificationService else { return nil }
    guard try await verifier.event(identifier: identifier) == nil else {
        throw EffectFailure.outcomeUnknown(
            operation: "calendar.deleteEvent.verify",
            cause: "Deleted event is still observable.",
            context: ["identifier": identifier]
        )
    }
    return true
}


