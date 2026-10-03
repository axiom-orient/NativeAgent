import Testing
import NativeAgentPresentation

@Test func customProvidersDoNotInheritAnotherProvidersReadiness() {
    let provider = AgentUIProvider(id: "custom", title: "Custom", symbol: "server.rack")
    let missing = AgentUIProvider(id: "missing", title: "Missing", symbol: "questionmark")
    let status = AgentUIStatus(providers: [.init(provider: provider, state: .ready)],
                             usageProvider: missing, usageRemainingPercent: 120)
    #expect(status.state(for: provider) == .ready)
    #expect(status.state(for: missing) == .unavailable)
    #expect(status.usageState == .unavailable)
    #expect(status.usageDescription == "사용량 확인 불가")
    #expect(status.usageRemainingPercent == 100)
}

@Test func transientStatesDoNotOfferSetupAndUnknownQuotaIsNotZero() {
    let provider = AgentUIProvider(id: "other", title: "Other", symbol: "cpu")
    for state in [AgentUIConnectionState.checking, .working] {
        let status = AgentUIStatus(providers: [.init(provider: provider, state: state)])
        #expect(!status.hasActionableSetup)
        #expect(status.needsConfiguration)
    }
    let ready = AgentUIStatus(providers: [.init(provider: provider, state: .ready)], usageProvider: provider)
    #expect(ready.usageRemainingPercent == nil)
    #expect(ready.usageDescription == "사용량 확인 중")
}

@Test func imageTasksCanUseAnyProvider() {
    let provider = AgentUIProvider(id: "local-image", title: "Local image", symbol: "cpu")
    let task = AgentUIWorkCapability(id: "image", title: "Generate", symbol: "photo",
        outcomeLabel: "Image", provider: provider, isAvailable: true, kind: .image)
    #expect(task.kind == .image)
    #expect(task.provider.id == "local-image")
    #expect(task.accessibilityID == "image")
}

@Test func customWorkKindsDoNotRequirePackageChanges() {
    let audio = AgentUIWorkKind(id: "audio", title: "Transcribe", symbol: "waveform")
    let provider = AgentUIProvider(id: "audio-provider", title: "Audio", symbol: "mic")
    let task = AgentUIWorkCapability(id: "transcribe", title: "Transcribe", symbol: "mic",
        outcomeLabel: "Transcript", provider: provider, isAvailable: true, kind: audio)
    #expect(task.kind.id == "audio")
}
