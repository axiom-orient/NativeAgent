import KnowledgeCore

package func isTransientPersistencePath(_ relativePath: String) throws -> Bool {
    try ASKValidation.requireRelativePath("relative_path", relativePath)
    return relativePath == "export-manifest.json"
        || relativePath == ".ask/materialize.lock"
        || relativePath == ".ask/generation/canonical.json"
        || relativePath == ".ask/generation/checkpoint.json"
        || relativePath == ".ask/generation/checkpoint-tail.json"
        || relativePath.hasPrefix(".ask/collector/")
}
