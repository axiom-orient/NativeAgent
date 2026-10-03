import Foundation
import NativeAgentDomain

#if canImport(Darwin)
import Darwin
#else
// Swift 6.2 Linux can attribute shared POSIX struct members to these C modules.
// Explicit imports preserve MemberImportVisibility in a cold module cache.
import CDispatch
import CoreFoundation
import Glibc
#endif

enum ToolPackBoundedFileReader {
    // I/O chunk size is a mechanism constant, not an accepted payload limit.
    private static let readChunkBytes = 64 * 1_024

    static func read(
        from url: URL,
        maximumByteCount: Int,
        label: String
    ) throws -> Data {
        guard maximumByteCount > 0 else {
            throw AgentError.invalidConfiguration("\(label) read limit must be positive.")
        }

        guard url.isFileURL, !url.path.utf8.contains(0) else {
            throw AgentError.invalidToolCall("\(label) must be a local file URL.")
        }
        // A byte limit alone cannot bound a blocking FIFO open. Do not follow
        // the final symlink; validate the actual opened object before reading.
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let operation: Result<Data, any Error>
        do {
            #if canImport(Darwin)
            var info = Darwin.stat()
            #else
            var info = Glibc.stat()
            #endif
            guard fstat(descriptor, &info) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
            }
            guard info.st_mode & S_IFMT == S_IFREG else {
                throw AgentError.invalidToolCall("\(label) must be a regular file.")
            }
            guard info.st_size >= 0, info.st_size <= maximumByteCount else {
                throw AgentError.budgetExceeded("\(label) exceeds \(maximumByteCount) bytes.")
            }
            var data = Data()
            data.reserveCapacity(min(maximumByteCount, readChunkBytes))
            while true {
                let remaining = maximumByteCount - data.count
                let count = remaining < readChunkBytes ? remaining + 1 : readChunkBytes
                guard let chunk = try handle.read(upToCount: count),
                    chunk.isEmpty == false
                else {
                    break
                }
                guard chunk.count <= remaining else {
                    throw AgentError.budgetExceeded(
                        "\(label) exceeds \(maximumByteCount) bytes."
                    )
                }
                data.append(chunk)
            }
            operation = .success(data)
        } catch {
            operation = .failure(error)
        }

        let cleanupError: (any Error)?
        do {
            try handle.close()
            cleanupError = nil
        } catch {
            cleanupError = error
        }
        return try OperationCleanupCompletionPolicy.resolve(
            operation: operation,
            cleanupError: cleanupError
        )
    }
}
