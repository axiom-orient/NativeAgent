import NativeAgentDomain
import Foundation

/// An explicit, host-owned capability boundary for WebKit features that can
/// expose user data or device resources. Every closure denies by default.
///
/// This object is intentionally not available through `BrowserToolPack`.
/// A consuming app must retain it and obtain any user and OS approvals before
/// returning an allow decision.
@MainActor
public final class BrowserHostIntegration {
    public typealias DownloadAuthorization = @MainActor @Sendable (BrowserDownloadRequest) -> Bool
    public typealias DownloadConsumer = @MainActor @Sendable (BrowserDownload) -> Void
    public typealias UploadProvider = @MainActor @Sendable (BrowserUploadRequest) -> [BrowserUpload]
    public typealias PopupAuthorization = @MainActor @Sendable (BrowserPopupRequest) -> BrowserPopupDecision
    public typealias MediaAuthorization = @MainActor @Sendable (BrowserMediaCaptureRequest) -> Bool
    public typealias AuthenticationHandler = @MainActor @Sendable (BrowserAuthenticationRequest) -> BrowserAuthenticationDecision

    private let downloadAuthorization: DownloadAuthorization
    private let downloadConsumer: DownloadConsumer
    private let uploadProvider: UploadProvider
    private let popupAuthorization: PopupAuthorization
    private let mediaAuthorization: MediaAuthorization
    private let authenticationHandler: AuthenticationHandler

    public init(
        downloadAuthorization: @escaping DownloadAuthorization = { _ in false },
        downloadConsumer: @escaping DownloadConsumer = { _ in },
        uploadProvider: @escaping UploadProvider = { _ in [] },
        popupAuthorization: @escaping PopupAuthorization = { _ in .deny },
        mediaAuthorization: @escaping MediaAuthorization = { _ in false },
        authenticationHandler: @escaping AuthenticationHandler = { _ in .cancel }
    ) {
        self.downloadAuthorization = downloadAuthorization
        self.downloadConsumer = downloadConsumer
        self.uploadProvider = uploadProvider
        self.popupAuthorization = popupAuthorization
        self.mediaAuthorization = mediaAuthorization
        self.authenticationHandler = authenticationHandler
    }

    func authorizes(_ request: BrowserDownloadRequest) -> Bool {
        downloadAuthorization(request)
    }

    func consume(_ download: BrowserDownload) {
        downloadConsumer(download)
    }

    func uploads(for request: BrowserUploadRequest) -> [BrowserUpload] {
        uploadProvider(request)
    }

    func popupDecision(for request: BrowserPopupRequest) -> BrowserPopupDecision {
        popupAuthorization(request)
    }

    func authorizes(_ request: BrowserMediaCaptureRequest) -> Bool {
        mediaAuthorization(request)
    }

    func authenticationDecision(
        for request: BrowserAuthenticationRequest
    ) -> BrowserAuthenticationDecision {
        authenticationHandler(request)
    }
}

public struct BrowserDownloadRequest: Sendable, Equatable {
    public let sourceOrigin: BrowserOrigin?
    public let mimeType: String?
    public let suggestedFilename: String?
    public let expectedByteCount: Int64?

    public init(
        sourceOrigin: BrowserOrigin?,
        mimeType: String?,
        suggestedFilename: String?,
        expectedByteCount: Int64?
    ) {
        self.sourceOrigin = sourceOrigin
        self.mimeType = mimeType
        self.suggestedFilename = suggestedFilename
        self.expectedByteCount = expectedByteCount
    }
}

public struct BrowserDownload: Sendable, Equatable {
    public let id: String
    public let sourceOrigin: BrowserOrigin?
    public let artifact: ArtifactWriteRequest

    public init(id: String = UUID().uuidString.lowercased(), sourceOrigin: BrowserOrigin?, artifact: ArtifactWriteRequest) {
        self.id = id
        self.sourceOrigin = sourceOrigin
        self.artifact = artifact
    }
}

/// File content selected by the consuming app, never a filesystem path chosen
/// by a page or an agent.
public struct BrowserUpload: Sendable, Equatable {
    public let preferredFilename: String
    public let mimeType: String
    public let data: Data

    public init(preferredFilename: String, mimeType: String, data: Data) {
        self.preferredFilename = preferredFilename
        self.mimeType = mimeType
        self.data = data
    }
}

public struct BrowserUploadRequest: Sendable, Equatable {
    public let sourceOrigin: BrowserOrigin?
    public let allowsMultipleSelection: Bool
    public let allowsDirectories: Bool

    public init(sourceOrigin: BrowserOrigin?, allowsMultipleSelection: Bool, allowsDirectories: Bool) {
        self.sourceOrigin = sourceOrigin
        self.allowsMultipleSelection = allowsMultipleSelection
        self.allowsDirectories = allowsDirectories
    }
}

public enum BrowserPopupDecision: Sendable, Equatable {
    case deny
    /// Replaces the current WebKit document. NativeAgent never creates an unbounded
    /// child WebView or exposes `window.opener` across an app boundary.
    case openInCurrentSession
}

public struct BrowserPopupRequest: Sendable, Equatable {
    public let sourceOrigin: BrowserOrigin?
    public let destinationOrigin: BrowserOrigin?

    public init(sourceOrigin: BrowserOrigin?, destinationOrigin: BrowserOrigin?) {
        self.sourceOrigin = sourceOrigin
        self.destinationOrigin = destinationOrigin
    }
}

public enum BrowserMediaCaptureKind: Sendable, Equatable {
    case audio
    case video
    case audioAndVideo
}

public struct BrowserMediaCaptureRequest: Sendable, Equatable {
    public let sourceOrigin: BrowserOrigin?
    public let kind: BrowserMediaCaptureKind

    public init(sourceOrigin: BrowserOrigin?, kind: BrowserMediaCaptureKind) {
        self.sourceOrigin = sourceOrigin
        self.kind = kind
    }
}

public enum BrowserAuthenticationMethod: String, Sendable, Equatable {
    case serverTrust
    case httpBasic
    case httpDigest
    case clientCertificate
    case ntlm
    case negotiate
    case other
}

public struct BrowserAuthenticationRequest: Sendable, Equatable {
    public let sourceOrigin: BrowserOrigin?
    public let method: BrowserAuthenticationMethod
    public let realm: String?
    public let isProxy: Bool

    public init(
        sourceOrigin: BrowserOrigin?,
        method: BrowserAuthenticationMethod,
        realm: String?,
        isProxy: Bool
    ) {
        self.sourceOrigin = sourceOrigin
        self.method = method
        self.realm = realm
        self.isProxy = isProxy
    }
}

/// Credentials are supplied only by the consuming app at challenge time and
/// are never observed, persisted, or made available to NativeAgent agent tools.
public enum BrowserAuthenticationDecision: Sendable {
    case cancel
    case performDefaultHandling
    case httpCredential(username: String, password: String)
}
