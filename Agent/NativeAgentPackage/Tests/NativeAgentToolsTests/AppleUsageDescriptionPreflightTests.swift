import NativeAgentDomain
import Foundation
import Testing

@testable import NativeAgentTools

@Test
func usageDescriptionPreflightRejectsMissingAndBlankValues() {
    #expect(throws: AgentError.self) {
        try validateHostUsageDescription(
            nil,
            key: "NSContactsUsageDescription",
            capability: "Contacts access"
        )
    }
    #expect(throws: AgentError.self) {
        try validateHostUsageDescription(
            "   ",
            key: "NSCalendarsFullAccessUsageDescription",
            capability: "Calendar full access"
        )
    }
}

@Test
func usageDescriptionPreflightAcceptsNonEmptyHostPurpose() throws {
    try validateHostUsageDescription(
        "Find people selected by the user.",
        key: "NSContactsUsageDescription",
        capability: "Contacts access"
    )
    try validateHostUsageDescription(
        "Create events approved by the user.",
        key: "NSCalendarsWriteOnlyAccessUsageDescription",
        capability: "Calendar write-only access"
    )
}

#if canImport(Contacts)
@available(iOS 17, *)
@Test
func contactsAdapterFailsClosedBeforeRequestingPermissionWithoutPurposeString() async {
    let service = CNContactStoreToolService()
    do {
        _ = try await service.search(query: "Ada", limit: 1, cursor: nil)
        Issue.record("Contacts permission must not be requested without a host purpose string.")
    } catch let error as AgentError {
        #expect(error.errorDescription?.contains("NSContactsUsageDescription") == true)
    } catch {
        Issue.record("Expected AgentError, got \(error)")
    }
}

@available(iOS 17, *)
@Test
func contactsAdapterRejectsEmptyQueryBeforePermissionPreflight() async throws {
    await #expect(throws: AgentError.self) {
        _ = try await CNContactStoreToolService().search(query: "  \n", limit: 1, cursor: nil)
    }
}
#endif

#if canImport(EventKit)
@available(iOS 17, *)
@Test
func calendarAdapterFailsClosedBeforeRequestingPermissionWithoutPurposeString() async {
    let service = EventKitCalendarToolService()
    do {
        _ = try await service.listEvents(
            startDate: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 60),
            limit: 1,
            cursor: nil
        )
        Issue.record("Calendar permission must not be requested without a host purpose string.")
    } catch let error as AgentError {
        #expect(error.errorDescription?.contains("NSCalendarsFullAccessUsageDescription") == true)
    } catch {
        Issue.record("Expected AgentError, got \(error)")
    }
}
#endif
