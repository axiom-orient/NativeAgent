import Foundation

protocol IDGenerator: Sendable {
    func uniqueID() -> String
}

struct UUIDGenerator: IDGenerator {
    func uniqueID() -> String { UUID().uuidString }
}

func uniqueID(_ generator: any IDGenerator = UUIDGenerator()) -> String {
    generator.uniqueID()
}
