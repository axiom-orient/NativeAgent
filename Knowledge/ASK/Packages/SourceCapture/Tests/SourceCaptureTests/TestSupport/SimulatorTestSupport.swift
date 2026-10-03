import Foundation

public enum SimulatorTestSupport {
    public static func makeTemporaryDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func testFileDirectory(filePath: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
    }

    public static func repoRootURL(filePath: StaticString = #filePath) -> URL {
        var dir = testFileDirectory(filePath: filePath)
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return dir
    }

    public static func fixtureURL(
        name: String,
        withExtension ext: String,
        subdirectory: String? = "Resources",
        filePath: StaticString = #filePath
    ) -> URL {
        let directory = testFileDirectory(filePath: filePath)
        let base = subdirectory.map { directory.appendingPathComponent($0, isDirectory: true) } ?? directory
        return base.appendingPathComponent(name).appendingPathExtension(ext)
    }
}
