import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Reads only regular files below an explicitly owned root. Each descendant is
/// opened relative to an already-open directory; symlinks cannot redirect I/O.
enum SourceRelocationFileReader {
    static func read(_ destination: URL, allowedRoots: [URL], expectedBytes: Int) throws -> Data {
        guard destination.isFileURL, expectedBytes >= 0, expectedBytes < Int.max else {
            throw failure("Invalid relocation destination or byte count")
        }
        let target = destination.standardizedFileURL
        let matches = allowedRoots.filter { root in
            root.isFileURL && target.path.hasPrefix(root.standardizedFileURL.path + "/")
        }
        guard let selected = matches.max(by: { $0.path.count < $1.path.count }) else {
            throw failure("Relocation destination is outside its owned roots")
        }
        let root = selected.standardizedFileURL
        let relative = String(target.path.dropFirst(root.path.count + 1))
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw failure("Invalid relocation relative path")
        }
        // Canonicalize only the trusted root, never the untrusted descendants.
        let rootPath = root.resolvingSymlinksInPath().path
        var directoryFD = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw failure("Cannot open owned relocation root") }
        defer { close(directoryFD) }
        for component in parts.dropLast() {
            let next = openat(directoryFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw failure("Relocation ancestor is missing or not a real directory") }
            close(directoryFD)
            directoryFD = next
        }
        let descriptor = openat(directoryFD, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("Relocation target is missing or is a symbolic link") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size >= 0, status.st_size == off_t(expectedBytes) else {
            throw failure("Relocation target is not a regular file with the indexed byte count")
        }
        var data = Data()
        while data.count <= expectedBytes {
            let capacity = min(65_536, expectedBytes - data.count + 1)
            guard let chunk = try handle.read(upToCount: capacity), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count == expectedBytes else { throw failure("Relocation target changed while reading") }
        return data
    }

    static func requireMissing(_ path: String) throws {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path)
            throw failure("An existing source locator cannot be replaced by relocation")
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        }
    }

    private static func failure(_ message: String) -> ASKPageIndexError {
        .invalidArguments(message)
    }
}
