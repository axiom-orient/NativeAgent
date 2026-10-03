import NativeAgentDomain
import Foundation
import Testing
@testable import NativeAgentStore

@Test
func defaultStoreBootstrapsSeparatelyFromAMAData() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let oldRoot = base.appendingPathComponent("App/AMA")
    try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
    let oldDatabase = oldRoot.appendingPathComponent("ama.sqlite3")
    let sentinel = Data("untouched legacy data".utf8)
    try sentinel.write(to: oldDatabase)

    let root = try StoreRootLocator.defaultRootURL(appName: "App", applicationSupportURL: base)
    #expect(root.lastPathComponent == "NativeAgent")
    let store = SQLiteSessionStore(
        rootURL: root, dataPolicy: .mobileDefault, artifactIDGenerator: { UUID().uuidString })
    try await store.prepare()
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("native-agent.sqlite3").path))
    #expect(try Data(contentsOf: oldDatabase) == sentinel)
    #expect(try FileManager.default.contentsOfDirectory(atPath: oldRoot.path) == ["ama.sqlite3"])
}

@Test
func defaultRootRejectsUnsafeAppNameComponents() {
    let baseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-store-root-tests", isDirectory: true)
    let unsafeComponents = [
        "",
        ".",
        "..",
        "../outside",
        "nested/path",
        #"nested\path"#,
        "contains\0nul",
        "contains\ncontrol",
        String(repeating: "a", count: 256),
    ]

    for component in unsafeComponents {
        #expect(throws: AgentError.self) {
            try StoreRootLocator.defaultRootURL(
                appName: component,
                applicationSupportURL: baseURL
            )
        }
    }
}

@Test
func defaultRootRejectsUnsafeStorageSubdirectoryComponents() {
    let baseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-store-root-tests", isDirectory: true)
    let unsafeComponents = [
        "",
        ".",
        "..",
        "../outside",
        "nested/path",
        #"nested\path"#,
        "contains\0nul",
        "contains\tcontrol",
        String(repeating: "a", count: 256),
    ]

    for component in unsafeComponents {
        #expect(throws: AgentError.self) {
            try StoreRootLocator.defaultRootURL(
                appName: "Safe App",
                subdirectoryName: component,
                applicationSupportURL: baseURL
            )
        }
    }
}

@Test
func defaultRootAllowsSafeUnicodeAndSpacesWithinStandardizedBase() throws {
    let unresolvedBaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-store-root-tests", isDirectory: true)
        .appendingPathComponent("intermediate", isDirectory: true)
        .appendingPathComponent("..", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
    let standardizedBaseURL = unresolvedBaseURL.standardizedFileURL

    let rootURL = try StoreRootLocator.defaultRootURL(
        appName: "세미 모바일",
        subdirectoryName: "에이전트 데이터",
        applicationSupportURL: unresolvedBaseURL
    )

    #expect(rootURL == standardizedBaseURL
        .appendingPathComponent("세미 모바일", isDirectory: true)
        .appendingPathComponent("에이전트 데이터", isDirectory: true)
        .standardizedFileURL)
    #expect(rootURL.pathComponents.starts(with: standardizedBaseURL.pathComponents))
    #expect(rootURL.pathComponents.count > standardizedBaseURL.pathComponents.count)
}

@Test
func defaultRootAllowsPathComponentsAtTheUTF8ByteLimit() throws {
    let baseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-agent-store-root-tests", isDirectory: true)
    let maximumLengthComponent = String(repeating: "a", count: 255)

    let rootURL = try StoreRootLocator.defaultRootURL(
        appName: maximumLengthComponent,
        subdirectoryName: maximumLengthComponent,
        applicationSupportURL: baseURL
    )

    #expect(rootURL.lastPathComponent == maximumLengthComponent)
    #expect(rootURL.deletingLastPathComponent().lastPathComponent == maximumLengthComponent)
}

@Test
func defaultRootUsesAndContainsAppGroupBase() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
    let appGroupBaseURL = temporaryDirectory
        .appendingPathComponent("native-agent-store-root-tests", isDirectory: true)
        .appendingPathComponent("group", isDirectory: true)
        .appendingPathComponent("..", isDirectory: true)
        .appendingPathComponent("Resolved Group", isDirectory: true)

    let rootURL = try StoreRootLocator.defaultRootURL(
        appName: "My App",
        appGroupIdentifier: "group.example.app",
        appGroupContainerURL: appGroupBaseURL,
        subdirectoryName: "Agent Data",
        applicationSupportURL: temporaryDirectory
            .appendingPathComponent("unused", isDirectory: true)
    )
    let standardizedBaseURL = appGroupBaseURL.standardizedFileURL

    #expect(rootURL.pathComponents.starts(with: standardizedBaseURL.pathComponents))
    #expect(rootURL.pathComponents.count > standardizedBaseURL.pathComponents.count)
}
