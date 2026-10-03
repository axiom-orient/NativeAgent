import Foundation

func stableID(_ prefix: String, _ parts: String...) -> String {
    var bytes: [UInt8] = []
    for part in parts {
        bytes += Array(part.utf8)
        bytes.append(0)
    }
    let hex = SHA256.hex(bytes)
    return prefix + "_" + String(hex.prefix(24))
}

func contentHash(_ content: String) -> String { SHA256.hex(Array(content.utf8)) }
