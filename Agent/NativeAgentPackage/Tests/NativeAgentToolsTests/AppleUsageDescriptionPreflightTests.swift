import NativeAgentDomain
import Foundation
import Testing

@testable import NativeAgentTools

@Test
func usageDescriptionPreflightRejectsMissingValue() {
    #expect(throws: AgentError.self) {
        try validateHostUsageDescription(
            nil,
            key: "NSContactsUsageDescription",
            capability: "Contacts access"
        )
    }
}

@Test
func usageDescriptionPreflightRejectsBlankValue() {
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
func contactsAdapterFailsClosedBeforeRequestingPermissionWithoutPurposeString() async throws {
    try await withMissingUsageDescriptionBundle { bundle in
        let service = CNContactStoreToolService(hostBundle: bundle)
        do {
            _ = try await service.search(query: "Ada", limit: 1, cursor: nil)
            Issue.record("Contacts permission must not be requested without a host purpose string.")
        } catch let error as AgentError {
            #expect(error.errorDescription?.contains("NSContactsUsageDescription") == true)
        } catch {
            Issue.record("Expected AgentError, got \(error)")
        }
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
func calendarAdapterFailsClosedBeforeRequestingPermissionWithoutPurposeString() async throws {
    try await withMissingUsageDescriptionBundle { bundle in
        let service = EventKitCalendarToolService(hostBundle: bundle)
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
}
#endif

// XCTest's runner declares its own privacy strings. It is not a missing-purpose
// fixture, so keep this adapter test independent of the runner's Info.plist.
private func withMissingUsageDescriptionBundle(
    _ body: (Bundle) async throws -> Void
) async throws {
    let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "native-agent-missing-purpose-\(UUID().uuidString).bundle")
    try FileManager.default.createDirectory(
        at: bundleURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundleURL) }
    let info = [
        "CFBundleIdentifier": "test.nativeagent.missing-purpose.\(UUID().uuidString)",
        "CFBundleName": "MissingPurpose", "CFBundlePackageType": "BNDL"
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
    let bundle = try #require(Bundle(url: bundleURL))
    for key in ["NSContactsUsageDescription", "NSCalendarsFullAccessUsageDescription",
                "NSCalendarsWriteOnlyAccessUsageDescription"] {
        #expect(bundle.object(forInfoDictionaryKey: key) == nil)
    }
    try await body(bundle)
}
