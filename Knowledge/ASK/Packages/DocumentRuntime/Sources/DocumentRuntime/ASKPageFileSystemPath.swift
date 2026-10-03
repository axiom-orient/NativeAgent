import Foundation
import DocumentCore

extension URL {
    var askPageFileSystemPath: String {
        standardizedFileURL.path(percentEncoded: false)
    }
}