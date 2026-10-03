import Foundation

/// Store-owned transaction state. A failed rollback poisons the connection until it is closed.
enum StoreTransactionState: Equatable {
    case idle
    case active(depth: Int)
    case rollbackRequired(StoreTransactionFailure)
    case poisoned(StoreTransactionFailure)
}

struct StoreTransactionFailure: Error, CustomStringConvertible, Sendable, Equatable {
    let stage: String
    let detail: String

    init(stage: String, error: any Error) {
        self.stage = stage
        self.detail = String(describing: error)
    }

    init(stage: String, detail: String) {
        self.stage = stage
        self.detail = detail
    }

    var description: String {
        "\(stage): \(detail)"
    }
}

struct StoreTransactionRollbackFailure: Error, CustomStringConvertible, Sendable, Equatable {
    let primary: StoreTransactionFailure
    let rollback: StoreTransactionFailure

    var description: String {
        "primary failure [\(primary)]; rollback failure [\(rollback)]"
    }
}
