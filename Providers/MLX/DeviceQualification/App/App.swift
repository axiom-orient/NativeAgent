import SwiftUI

@main
struct NativeAgentMLXDeviceQualificationApp: App {
  var body: some Scene {
    WindowGroup {
      ScrollView { VStack(spacing: 12) {
        Image(systemName: "checkmark.shield")
          .font(.system(size: 42))
        Text("NativeAgent MLX qualification host")
          .font(.headline)
        Text("Run the shared app-hosted XCTest scheme to qualify a physical device.")
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
      }
        Divider()
        AppleQualificationView()
      }
      .padding()
    }
  }
}
