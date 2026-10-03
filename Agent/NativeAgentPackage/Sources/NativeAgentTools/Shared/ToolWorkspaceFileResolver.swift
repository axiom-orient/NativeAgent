import Foundation
import NativeAgentDomain

/// Resolves one existing, regular file inside the current agent session.
///
/// File-consuming device tools receive URLs only after this boundary has
/// checked the runtime-owned session directory, containment, and symlinks.
/// They never accept arbitrary host URLs from model input.
enum ToolWorkspaceFileResolver {
    static func readableFile(
        relativePath: String,
        context: ToolExecutionContext,
        maximumByteCount: Int,
        label: String,
        allowedExtensions: Set<String> = []
    ) throws -> URL {
        guard maximumByteCount > 0 else {
            throw AgentError.invalidConfiguration("\(label) input limit must be positive.")
        }

        let sessionDirectory = context.sessionDirectoryURL.standardizedFileURL
        let sandboxRoot = context.sandboxRootURL.standardizedFileURL
        guard sessionDirectory.isFileURL, sandboxRoot.isFileURL else {
            throw AgentError.pathOutsideSandbox("\(label) requires file URLs for the session workspace.")
        }

        let rootPath = sandboxRoot.path.hasSuffix("/") ? sandboxRoot.path : sandboxRoot.path + "/"
        let sessionPath = sessionDirectory.path
        guard sessionPath == sandboxRoot.path || sessionPath.hasPrefix(rootPath) else {
            throw AgentError.pathOutsideSandbox("Session workspace is outside the runtime sandbox.")
        }

        let resolver = FilesSandboxPathResolver(rootURL: sessionDirectory)
        let url = try resolver.resolve(path: relativePath)
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .isSymbolicLinkKey,
        ])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw AgentError.invalidToolCall("\(label) input must name an existing regular file.")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw AgentError.accessDenied("\(label) input file is not readable.")
        }
        guard let byteCount = values.fileSize, byteCount <= maximumByteCount else {
            throw AgentError.budgetExceeded("\(label) input exceeds \(maximumByteCount) bytes.")
        }

        if allowedExtensions.isEmpty == false {
            let pathExtension = url.pathExtension.lowercased()
            guard allowedExtensions.contains(pathExtension) else {
                throw AgentError.invalidToolCall("\(label) input has an unsupported file type.")
            }
        }

        return url
    }
}
