import Foundation

public extension JSONEncoder {
    static func nativeAgent(sortedKeys: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        if sortedKeys {
            encoder.outputFormatting = [.sortedKeys]
        }
        return encoder
    }
}

public extension JSONDecoder {
    static func nativeAgent() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
