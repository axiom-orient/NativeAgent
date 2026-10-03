import Foundation

extension ASKIOSFMFKernel {
    public func execute(tool: String, argumentsJSON: String = "{}") async throws -> String {
        try await bridge.execute(tool: tool, argumentsJSON: argumentsJSON)
    }
}
