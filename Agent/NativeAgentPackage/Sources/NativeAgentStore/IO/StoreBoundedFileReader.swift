import Foundation
import NativeAgentDomain

enum StoreBoundedFileReader {
    static let defaultJSONLimit = 64 * 1_024 * 1_024
    private static let readChunkBytes = 64 * 1_024

    static func read(
        from url: URL,
        maximumByteCount: Int,
        label: String
    ) throws -> Data {
        guard maximumByteCount >= 0 else {
            throw AgentError.invalidConfiguration(
                "\(label) maximum byte count must be nonnegative."
            )
        }

        return try withReadHandle(from: url, label: label) { handle in
            var data = Data()
            data.reserveCapacity(min(maximumByteCount, Self.readChunkBytes))

            while true {
                let remaining = maximumByteCount - data.count
                let requestCount = remaining >= Self.readChunkBytes
                    ? Self.readChunkBytes
                    : remaining + 1
                guard let chunk = try handle.read(upToCount: requestCount),
                      chunk.isEmpty == false else {
                    break
                }
                guard chunk.count <= remaining else {
                    throw AgentError.budgetExceeded(
                        "\(label) exceeds \(maximumByteCount) bytes."
                    )
                }
                data.append(chunk)
            }
            return data
        }
    }

    static func digestAndCount(
        from url: URL,
        maximumByteCount: Int,
        label: String
    ) throws -> (digest: String, byteCount: Int) {
        guard maximumByteCount >= 0 else {
            throw AgentError.invalidConfiguration(
                "\(label) maximum byte count must be nonnegative."
            )
        }

        return try withReadHandle(from: url, label: label) { handle in
            var accumulator = SHA256Accumulator()
            var byteCount = 0

            while true {
                let remaining = maximumByteCount - byteCount
                let requestCount = remaining >= Self.readChunkBytes
                    ? Self.readChunkBytes
                    : remaining + 1
                guard let chunk = try handle.read(upToCount: requestCount),
                      chunk.isEmpty == false else {
                    break
                }
                guard chunk.count <= remaining else {
                    throw AgentError.budgetExceeded(
                        "\(label) exceeds \(maximumByteCount) bytes."
                    )
                }
                accumulator.update(chunk)
                byteCount += chunk.count
            }

            return (accumulator.finalizeHex(), byteCount)
        }
    }

    private static func withReadHandle<Result>(
        from url: URL,
        label: String,
        operation: (FileHandle) throws -> Result
    ) throws -> Result {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw AgentError.persistenceFailure(
                "Unable to open \(label): \(error.localizedDescription)"
            )
        }

        let operationResult: Swift.Result<Result, any Error>
        do {
            operationResult = .success(try operation(handle))
        } catch {
            operationResult = .failure(error)
        }

        let cleanupError: (any Error)?
        do {
            try handle.close()
            cleanupError = nil
        } catch {
            cleanupError = error
        }
        return try OperationCleanupCompletionPolicy.resolve(
            operation: operationResult,
            cleanupError: cleanupError
        )
    }
}
