import LanguageModelCore
import Foundation

public struct CapabilityID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.init(rawValue: value)
    }

    public static let files: CapabilityID = "files"
    public static let calendar: CapabilityID = "calendar"
    public static let contacts: CapabilityID = "contacts"
    public static let appIntents: CapabilityID = "app_intents"
    public static let photos: CapabilityID = "photos"
    public static let health: CapabilityID = "health"
    public static let vision: CapabilityID = "vision"
    public static let speech: CapabilityID = "speech"
    public static let maps: CapabilityID = "maps"
    public static let nfc: CapabilityID = "nfc"
    public static let skills: CapabilityID = "skills"
    public static let images: CapabilityID = "images"
    public static let mcp: CapabilityID = "mcp"
    public static let browser: CapabilityID = "browser"
}

public enum ApprovalPolicy: String, Codable, Sendable, Equatable {
    case automatic
    case requireApproval
    case alwaysDeny
}

public enum SessionStatus: String, Codable, Sendable, Equatable {
    case running
    case waiting
    case completed
    case failed
}
