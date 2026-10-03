import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentTools

func noopContext(root: URL) -> ToolExecutionContext {
    ToolExecutionContext(
        sessionID: "session",
        sessionDirectoryURL: root,
        sandboxRootURL: root
    )
}

func makeToolPackTempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}
