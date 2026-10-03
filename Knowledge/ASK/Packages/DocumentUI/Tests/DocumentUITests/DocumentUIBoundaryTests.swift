import Foundation
import Testing
@testable import DocumentUI

#if canImport(SwiftUI)
@MainActor
@Test("DocumentUI constructs the native viewer with the requested document")
func documentUIConstructsNativeViewer() {
    let documentURL = URL(fileURLWithPath: "/tmp/document-ui-boundary.hwpx")
    let viewer = ASKPageHWPNativeTextViewer(documentURL: documentURL)

    #expect(viewer.documentURL == documentURL)
    _ = viewer.body
}
#endif
