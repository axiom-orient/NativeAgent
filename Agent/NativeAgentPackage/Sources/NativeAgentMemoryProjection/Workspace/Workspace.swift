import Foundation

/// Filesystem location for the derived memory projection.
///
/// Location is not identity. The authoritative workspace identifier is stored
/// inside the SQLite projection and is owned by `Store`.
struct WorkspacePaths {
    let root: String
    let db: String
}

struct Workspace {
    let paths: WorkspacePaths
}

func resolveDataDir(_ input: String) throws -> String {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
        throw AppError.workspace(
            "missing_data_dir",
            "data directory must be provided by the host application"
        )
    }
    guard value.hasPrefix("/") else {
        throw AppError.workspace(
            "relative_data_dir",
            "data directory must be an absolute app-owned path"
        )
    }
    return containmentPath(value)
}

func buildPaths(_ root: String) -> WorkspacePaths {
    let url = URL(fileURLWithPath: root)
    return WorkspacePaths(
        root: root,
        db: url.appendingPathComponent("memories.db").path
    )
}

func ensureInside(_ root: String, _ target: String) throws {
    let canonicalRoot = containmentPath(root)
    let canonicalTarget = containmentPath(target)
    guard canonicalTarget == canonicalRoot || canonicalTarget.hasPrefix(canonicalRoot + "/") else {
        throw AppError.workspace("path_outside_workspace", "path escapes workspace")
    }
}

private func containmentPath(_ path: String) -> String {
    var cursor = URL(fileURLWithPath: path).standardizedFileURL
    var missingComponents: [String] = []

    while !FileManager.default.fileExists(atPath: cursor.path) {
        let parent = cursor.deletingLastPathComponent()
        if parent.path == cursor.path { break }
        missingComponents.append(cursor.lastPathComponent)
        cursor = parent
    }

    var result = cursor.resolvingSymlinksInPath().standardizedFileURL
    for component in missingComponents.reversed() {
        result.appendPathComponent(component)
    }
    return result.path
}

func initWorkspace(_ dataDir: String) throws -> Workspace {
    let root = try resolveDataDir(dataDir)
    let paths = buildPaths(root)
    try ensureInside(root, paths.db)
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return Workspace(paths: paths)
}

func openWorkspace(_ dataDir: String) throws -> Workspace {
    let root = try resolveDataDir(dataDir)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw AppError.workspace("workspace_missing", "workspace is missing; initialize memory first")
    }
    let paths = buildPaths(root)
    try ensureInside(root, paths.db)
    return Workspace(paths: paths)
}
