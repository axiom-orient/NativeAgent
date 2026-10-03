import Foundation
import NativeAgentDomain

extension URL {
    func appendingRelativePath(from root: URL, to child: URL, isDirectory: Bool) throws -> URL {
        let rootComponents = root.standardizedFileURL.pathComponents
        let childComponents = child.standardizedFileURL.pathComponents
        guard childComponents.starts(with: rootComponents) else {
            throw AgentError.invalidToolCall("Imported skill entry escaped the selected directory")
        }
        let relativeComponents = childComponents.dropFirst(rootComponents.count)
        let relativePath = NSString.path(withComponents: Array(relativeComponents))
        return appendingPathComponent(relativePath, isDirectory: isDirectory).standardizedFileURL
    }
}

extension String {
    func dropPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }

    var normalizedJSONPayload: String {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "{}" : t
    }
}
