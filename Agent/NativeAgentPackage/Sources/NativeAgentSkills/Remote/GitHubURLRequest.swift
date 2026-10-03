import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

extension URLRequest {
    mutating func applyGitHubHeaders(accept: String) {
        setValue(accept, forHTTPHeaderField: "Accept")
        setValue("NativeAgent-iOS-SkillInstaller", forHTTPHeaderField: "User-Agent")
        setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    }
}
