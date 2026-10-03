import Foundation

/// Cheap change signal for a source index workspace: attributes of the
/// manifest file, which every mutation rewrites atomically. `nil` means the
/// workspace has no manifest yet.
public struct SourceIndexRevisionToken: Equatable, Sendable {
    public let modificationDate: Date
    public let size: UInt64

    init(modificationDate: Date, size: UInt64) {
        self.modificationDate = modificationDate
        self.size = size
    }
}
