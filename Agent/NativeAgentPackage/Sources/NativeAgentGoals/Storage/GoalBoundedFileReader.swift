import Foundation
import NativeAgentDomain

enum GoalBoundedFileReader {
    static func read(from url: URL, label: String) throws -> Data {
        let maximumByteCount = GoalResourceLimits.maximumGoalFileBytes
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw GoalError.storeFailure(
                "failed to open \(label): \(error.localizedDescription)"
            )
        }

        let operation: Result<Data, any Error>
        do {
            var data = Data()
            data.reserveCapacity(min(maximumByteCount, 64 * 1_024))
            while true {
                let remaining = maximumByteCount - data.count
                let requestCount = min(64 * 1_024, remaining + 1)
                guard let chunk = try handle.read(upToCount: requestCount),
                      chunk.isEmpty == false else {
                    break
                }
                guard chunk.count <= remaining else {
                    throw GoalError.storeFailure(
                        "\(label) exceeds \(maximumByteCount) bytes"
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
