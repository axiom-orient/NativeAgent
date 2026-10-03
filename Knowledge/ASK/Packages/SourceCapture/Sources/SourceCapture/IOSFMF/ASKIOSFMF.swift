import Foundation
import KnowledgeCore
import KnowledgeRuntime

public struct ASKIOSFMFConfiguration: Equatable, Sendable {
    public var rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }
}

public actor ASKIOSFMFKernel {
    package let runtime: ASKRuntime
    package let bridge: ASKJSONToolExecutor

    public init(configuration: ASKIOSFMFConfiguration) {
        let runtime = ASKRuntime(root: configuration.rootURL)
        self.runtime = runtime
        self.bridge = ASKJSONToolExecutor(runtime: runtime)
    }

    public init(root: URL) {
        self.init(configuration: ASKIOSFMFConfiguration(rootURL: root))
    }
}
