import Foundation

extension URL {
    package var askProductFileSystemPath: String {
        standardizedFileURL.path(percentEncoded: false)
    }
}