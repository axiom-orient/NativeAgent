import Foundation
import NativeAgentDomain

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Cross-process session ownership backed by an advisory OS file lock.
/// The kernel releases the lock when the owning process exits, so a crashed
/// process cannot strand a durable session behind an unrecoverable claim token.
package actor ApplicationSupportFileExecutionClaimStore: SessionExecutionClaimStore {
    private struct OwnedClaim {
        let claim: SessionExecutionClaim
        let lock: SessionExecutionFileLock
    }

    private let rootURL: URL
    private var owned: [String: OwnedClaim] = [:]

    package init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    package func acquireExecutionClaim(sessionID: String) async throws -> SessionExecutionClaim {
        let validated = try ValidatedSessionID(sessionID)
        guard owned[validated.rawValue] == nil else {
            throw AgentError.sessionBusy(validated.rawValue)
        }

        let lock: SessionExecutionFileLock
        do {
            lock = try SessionExecutionFileLock(rootURL: rootURL, sessionID: validated.rawValue)
        } catch SessionExecutionFileLockError.busy {
            throw AgentError.sessionBusy(validated.rawValue)
        } catch {
            throw AgentError.persistenceFailure(
                "Failed to acquire cross-process session execution claim for \(validated.rawValue)."
            )
        }

        let claim = SessionExecutionClaim(
            sessionID: validated.rawValue,
            claimID: UUID().uuidString
        )
        owned[validated.rawValue] = OwnedClaim(claim: claim, lock: lock)
        return claim
    }

    package func releaseExecutionClaim(_ claim: SessionExecutionClaim) async throws {
        guard let current = owned[claim.sessionID], current.claim == claim else {
            throw AgentError.persistenceFailure(
                "Session execution claim is no longer owned: \(claim.sessionID)"
            )
        }
        guard current.lock.unlock() else {
            throw AgentError.persistenceFailure(
                "Failed to release cross-process session execution claim for \(claim.sessionID)."
            )
        }
        owned.removeValue(forKey: claim.sessionID)
    }
}

private enum SessionExecutionFileLockError: Error {
    case busy
    case storage
}

private final class SessionExecutionFileLock: @unchecked Sendable {
    private let handle: FileHandle
    private let mutex = NSLock()
    private var lockHeld = true
    private var handleClosed = false

    init(rootURL: URL, sessionID: String) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let rootDescriptor = rootURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else { throw SessionExecutionFileLockError.storage }
        defer { sessionClaimClose(rootDescriptor) }

        let directoryName = ".execution-locks"
        let createResult = directoryName.withCString { mkdirat(rootDescriptor, $0, S_IRWXU) }
        guard createResult == 0 || errno == EEXIST else {
            throw SessionExecutionFileLockError.storage
        }
        let directoryDescriptor = directoryName.withCString {
            openat(rootDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else { throw SessionExecutionFileLockError.storage }
        defer { sessionClaimClose(directoryDescriptor) }

        let filename = "\(sessionID).lock"
        let descriptor = filename.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else { throw SessionExecutionFileLockError.storage }

        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_nlink == 1 else {
            sessionClaimClose(descriptor)
            throw SessionExecutionFileLockError.storage
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            sessionClaimClose(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw SessionExecutionFileLockError.busy
            }
            throw SessionExecutionFileLockError.storage
        }

        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    @discardableResult
    func unlock() -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        if lockHeld {
            guard flock(handle.fileDescriptor, LOCK_UN) == 0 else { return false }
            lockHeld = false
        }
        guard !handleClosed else { return true }
        do {
            try handle.close()
            handleClosed = true
            return true
        } catch {
            return false
        }
    }

    deinit {
        _ = unlock()
    }
}

private func sessionClaimClose(_ descriptor: Int32) {
#if canImport(Darwin)
    _ = Darwin.close(descriptor)
#else
    _ = Glibc.close(descriptor)
#endif
}
