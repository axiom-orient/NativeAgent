import Foundation

public enum StoreFileProtection: String, Codable, Sendable, Equatable, CaseIterable {
    case complete
    case completeUnlessOpen
    case completeUntilFirstUserAuthentication
    case none
}

/// Host-selectable iOS persistence policy. Session data is user data, so it is
/// included in backup by default and protected after the first device unlock.
public struct StoreDataPolicy: Codable, Sendable, Equatable {
    public let excludeFromBackup: Bool
    public let fileProtection: StoreFileProtection

    public init(
        excludeFromBackup: Bool = false,
        fileProtection: StoreFileProtection = .completeUntilFirstUserAuthentication
    ) {
        self.excludeFromBackup = excludeFromBackup
        self.fileProtection = fileProtection
    }

    public static let mobileDefault = StoreDataPolicy()

    func apply(to url: URL, fileManager: FileManager) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excludeFromBackup
        try mutableURL.setResourceValues(values)

#if os(iOS)
        let protection: FileProtectionType
        switch fileProtection {
        case .complete:
            protection = .complete
        case .completeUnlessOpen:
            protection = .completeUnlessOpen
        case .completeUntilFirstUserAuthentication:
            protection = .completeUntilFirstUserAuthentication
        case .none:
            protection = .none
        }
        try fileManager.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: url.path
        )
#endif
    }
}
