
/// Desktop-only expansion surface for bridge, capture, and external-tool
/// workflows.
///
/// The mobile product must not depend on this target.
public enum ASKDesktopExtension {
    public static let identifier = "ask.desktop-extension"

    public static let capabilities: [ASKDesktopExtensionCapability] = [
        .jsonBridge,
        .webCapture,
        .httpCapture,
        .captureStaging,
        .iosFMFBridge,
    ]
}

public enum ASKDesktopExtensionCapability: String, Codable, CaseIterable, Sendable {
    case jsonBridge = "json_bridge"
    case webCapture = "web_capture"
    case httpCapture = "http_capture"
    case captureStaging = "capture_staging"
    case iosFMFBridge = "ios_fmf_bridge"
}
