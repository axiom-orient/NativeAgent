/// A coherent Agent extension that contributes executable tools and the
/// prompt rules required to use them correctly.
///
/// Capabilities are composition values. Durable session state, persistence,
/// approval, execution ordering, and recovery remain owned by `NativeAgentExecution`.
public protocol AgentCapability: ToolPack, PromptAugmentor {}
