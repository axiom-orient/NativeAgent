import Foundation
import LanguageModelCore
import Testing

@testable import LanguageModelRuntime

@Suite("ModelRuntime authority")
struct ModelRuntimeTests {
  @Test func statusDecodeRejectsPhaseIncompatiblePayload() throws {
    let malformed = Data(#"{"phase":"running"}"#.utf8)
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(ModelRuntimeStatus.self, from: malformed)
    }
  }

  @Test func successfulRunUsesCanonicalDescriptorAndReturnsToIdle() async throws {
    let descriptor = Self.descriptor()
    let client = ScriptedClient(
      providerID: descriptor.providerID,
      modelDescriptor: nil,
      events: [
        .started(descriptor: nil),
        .textDelta("hello"),
        .completed(ModelTurn(content: "hello", stopReason: .stop)),
      ])
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.local"),
      client: client,
      descriptor: descriptor)

    let run = try await runtime.start(Self.request())
    let events = try await Self.collect(run.events)

    #expect(
      events == [
        .started(descriptor: descriptor),
        .textDelta("hello"),
        .completed(ModelTurn(content: "hello", stopReason: .stop)),
      ])
    #expect(await runtime.status().phase == .idle)
  }

  @Test func effectStateTracksProviderStartedBoundary() async throws {
    let descriptor = Self.descriptor()

    let preStartRuntime = try ModelRuntime(
      id: .init(rawValue: "runtime.effect.pre-start"),
      client: PreStartFailureClient(
        providerID: descriptor.providerID,
        modelDescriptor: descriptor
      )
    )
    let preStartRun = try await preStartRuntime.start(Self.request())
    do {
      _ = try await Self.collect(preStartRun.events)
      Issue.record("Pre-start provider failure unexpectedly completed.")
    } catch {}
    #expect(preStartRun.effectState == .notStarted)

    let postStartRuntime = try ModelRuntime(
      id: .init(rawValue: "runtime.effect.post-start"),
      client: TypedFailureClient(
        providerID: descriptor.providerID,
        modelDescriptor: descriptor
      )
    )
    let postStartRun = try await postStartRuntime.start(Self.request())
    do {
      _ = try await Self.collect(postStartRun.events)
      Issue.record("Post-start provider failure unexpectedly completed.")
    } catch {}
    #expect(postStartRun.effectState == .started)
  }

  @Test func concurrentStartsReserveExactlyOneRunBeforeAnyAwait() async throws {
    let descriptor = Self.descriptor()
    let source = ControlledSource()
    let client = ControlledClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor,
      source: source)
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.single-owner"),
      client: client)

    let outcomes = await withTaskGroup(of: StartOutcome.self, returning: [StartOutcome].self) {
      group in
      for _ in 0..<16 {
        group.addTask {
          do {
            return .started(try await runtime.start(Self.request()))
          } catch let failure as ModelRuntimeFailure where failure.code == .busy {
            return .busy
          } catch {
            return .unexpected(String(describing: error))
          }
        }
      }
      var values: [StartOutcome] = []
      for await value in group { values.append(value) }
      return values
    }

    let runs = outcomes.compactMap(\.run)
    #expect(runs.count == 1)
    #expect(outcomes.filter(\.isBusy).count == 15)
    #expect(outcomes.filter(\.isUnexpected).isEmpty)

    try await Self.waitUntil { source.isConnected }
    source.yield(.started(descriptor: descriptor))
    source.yield(.completed(ModelTurn(content: "done", stopReason: .stop)))
    source.finish()
    _ = try await Self.collect(try #require(runs.first).events)
    #expect(await runtime.status().phase == .idle)
  }

  @Test func reservationDefersProviderEntryUntilExplicitStart() async throws {
    let descriptor = Self.descriptor()
    let probe = InvocationProbe()
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.reservation"),
      client: CountingClient(
        providerID: descriptor.providerID,
        modelDescriptor: descriptor,
        probe: probe
      )
    )

    let reservation = try await runtime.reserve(Self.request())
    let reservedStatus = await runtime.status()
    #expect(reservedStatus.phase == .reserved)
    #expect(reservedStatus.activeRunID == reservation.runID)
    #expect(probe.invocations == 0)

    do {
      _ = try await runtime.reserve(Self.request())
      Issue.record("An occupied reservation unexpectedly admitted another request.")
    } catch let failure as ModelRuntimeFailure {
      #expect(failure.code == .busy)
    }
    #expect(probe.invocations == 0)

    let run = try await runtime.start(reservation)
    _ = try await Self.collect(run.events)
    #expect(probe.invocations == 1)
    #expect(await runtime.status().phase == .idle)
  }

  @Test func staleReservationReleaseCannotClearNewerOwnership() async throws {
    let descriptor = Self.descriptor()
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.reservation-identity"),
      client: ScriptedClient(
        providerID: descriptor.providerID,
        modelDescriptor: descriptor,
        events: []
      )
    )

    let first = try await runtime.reserve(Self.request())
    #expect(await runtime.release(first))
    let second = try await runtime.reserve(Self.request())

    #expect(await runtime.release(first) == false)
    let status = await runtime.status()
    #expect(status.phase == .reserved)
    #expect(status.activeRunID == second.runID)
    #expect(await runtime.release(second))
    #expect(await runtime.status().phase == .idle)
  }

  @Test func shutdownInvalidatesReservationWithoutEnteringProvider() async throws {
    let descriptor = Self.descriptor()
    let providerProbe = InvocationProbe()
    let cleanupProbe = InvocationProbe()
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.reservation-shutdown"),
      client: CountingClient(
        providerID: descriptor.providerID,
        modelDescriptor: descriptor,
        probe: providerProbe
      ),
      cleanup: { cleanupProbe.record() }
    )

    let reservation = try await runtime.reserve(Self.request())
    try await runtime.shutdown()

    #expect(providerProbe.invocations == 0)
    #expect(cleanupProbe.invocations == 1)
    #expect(await runtime.status().phase == .closed)
    do {
      _ = try await runtime.start(reservation)
      Issue.record("A reservation survived runtime shutdown.")
    } catch let failure as ModelRuntimeFailure {
      #expect(failure.code == .closed)
    }
  }

  @Test func invalidAndMismatchedRequestsFailBeforeProviderInvocation() async throws {
    let descriptor = Self.descriptor()
    let probe = InvocationProbe()
    let client = CountingClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor,
      probe: probe)
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.validation"),
      client: client)

    do {
      _ = try await runtime.start(
        ModelRequest(sessionID: "bad id", messages: [.init(role: .user, content: "x")], tools: []))
      Issue.record("Invalid request unexpectedly started.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .invalidRequest)
    }

    do {
      _ = try await runtime.start(Self.request(modelID: "different-model"))
      Issue.record("Mismatched model unexpectedly started.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .invalidRequest)
    }

    do {
      _ = try await runtime.start(Self.request(modelID: "invalid model id"))
      Issue.record("Invalid model identity unexpectedly started.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .invalidRequest)
    }

    do {
      let request = ModelRequest(
        sessionID: "session-unknown-capability",
        messages: [.init(role: .user, content: "hello")],
        tools: [],
        requiredCapabilities: ModelCapabilities(rawValue: 1 << 63)
      )
      _ = try await runtime.start(request)
      Issue.record("Unknown capability unexpectedly started.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .invalidRequest)
    }

    #expect(probe.invocations == 0)
    #expect(await runtime.status().phase == .idle)
  }

  @Test func invalidDescriptorCannotCreateRuntime() throws {
    let invalid = ModelDescriptor(
      id: "invalid model id",
      providerID: "provider.test",
      capabilities: [.textInput, .textOutput])
    let client = ScriptedClient(
      providerID: invalid.providerID,
      modelDescriptor: invalid,
      events: [])

    do {
      _ = try ModelRuntime(
        id: .init(rawValue: "runtime.invalid-descriptor"),
        client: client)
      Issue.record("Invalid descriptor unexpectedly created a runtime.")
    } catch let failure as ModelRuntimeFailure {
      #expect(failure.code == .invalidConfiguration)
    }
  }

  @Test func unsolicitedProviderCancellationIsTransportFailure() async throws {
    let descriptor = Self.descriptor()
    let client = ProviderCancellationClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor)
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.provider-cancel"),
      client: client)

    let run = try await runtime.start(Self.request())
    do {
      _ = try await Self.collect(run.events)
      Issue.record("Provider-owned cancellation was treated as caller cancellation.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .transportFailure)
    }
  }

  @Test func typedProviderFailureCrossesRuntimeBoundaryIntact() async throws {
    let descriptor = Self.descriptor()
    let client = TypedFailureClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor)
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.typed-failure"),
      client: client)

    let run = try await runtime.start(Self.request())
    do {
      _ = try await Self.collect(run.events)
      Issue.record("Typed provider failure was hidden.")
    } catch let failure as TypedProviderFailure {
      #expect(failure.modelFailureCode == "provider_rate_limited")
      #expect(failure.modelFailureDetails["retryAfterSeconds"] == .integer(7))
    }
  }

  @Test func outputCapabilityIsDerivedEvenWhenCallerOmitsIt() async throws {
    let descriptor = Self.descriptor(
      capabilities: [.textInput, .streaming]
    )
    let probe = InvocationProbe()
    let client = CountingClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor,
      probe: probe)
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime-derived-output"),
      client: client)
    let request = ModelRequest(
      sessionID: "session-derived-output",
      modelID: descriptor.id,
      messages: [.init(role: .user, content: "hello")],
      tools: [],
      requiredCapabilities: [.textInput, .streaming]
    )

    do {
      _ = try await runtime.start(request)
      Issue.record("Caller weakened the actual output capability requirement.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .policyViolation)
    }
    #expect(probe.invocations == 0)
  }

  @Test func structuredOutputRequiresExplicitProviderCapability() async throws {
    let descriptor = Self.descriptor()
    let probe = InvocationProbe()
    let client = CountingClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor,
      probe: probe)
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.structured-output"),
      client: client)
    let request = ModelRequest(
      sessionID: "session-structured",
      modelID: descriptor.id,
      messages: [.init(role: .user, content: "return json")],
      tools: [],
      requiredCapabilities: [.textInput, .textOutput, .streaming],
      outputFormat: .jsonObject(schema: .object(["type": .string("object")]))
    )

    do {
      _ = try await runtime.start(request)
      Issue.record("Prompt-only JSON support was treated as schema enforcement.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .policyViolation)
    }
    #expect(probe.invocations == 0)
  }

  @Test func providerDescriptorConflictFailsClosed() async throws {
    let selected = Self.descriptor(id: "selected")
    let emitted = Self.descriptor(id: "other")
    let client = ScriptedClient(
      providerID: selected.providerID,
      modelDescriptor: selected,
      events: [
        .started(descriptor: emitted),
        .completed(ModelTurn(content: "unreachable")),
      ])
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.descriptor"),
      client: client)

    let run = try await runtime.start(Self.request(modelID: selected.id))
    do {
      _ = try await Self.collect(run.events)
      Issue.record("Conflicting provider descriptor unexpectedly passed.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .malformedEvent)
    }
    try await Self.waitUntil { await runtime.status().phase == .idle }
  }

  @Test func streamContractMismatchIsRejected() async throws {
    let descriptor = Self.descriptor()
    let client = ScriptedClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor,
      events: [
        .started(descriptor: descriptor),
        .textDelta("partial"),
        .completed(ModelTurn(content: "different")),
      ])
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.contract"),
      client: client)

    let run = try await runtime.start(Self.request())
    do {
      _ = try await Self.collect(run.events)
      Issue.record("Mismatched terminal content unexpectedly passed.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .malformedEvent)
    }
  }

  @Test func generateReturnsOnlyTheAuthoritativeCompletedTurnAfterEOF() async throws {
    let descriptor = Self.descriptor()
    let client = ScriptedClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor,
      events: [
        .started(descriptor: descriptor),
        .textDelta("done"),
        .completed(ModelTurn(content: "done", stopReason: .stop)),
      ])
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.generate"),
      client: client)

    let turn = try await runtime.generate(Self.request())
    #expect(turn.content == "done")
    #expect(await runtime.status().phase == .idle)
  }

  @Test func terminalResultAndFailurePublishPostRunStateBeforeReturning() async throws {
    let descriptor = Self.descriptor()
    let successfulRuntime = try ModelRuntime(
      id: .init(rawValue: "runtime.terminal-publication.success"),
      client: ScriptedClient(
        providerID: descriptor.providerID,
        modelDescriptor: descriptor,
        events: [
          .started(descriptor: descriptor),
          .completed(ModelTurn(content: "done", stopReason: .stop)),
        ]))

    for iteration in 0..<2_000 {
      _ = try await successfulRuntime.generate(Self.request())
      let phase = await successfulRuntime.status().phase
      guard phase == .idle else {
        Issue.record(
          "Successful terminal returned before idle at iteration \(iteration): \(phase)")
        return
      }
    }

    let failingRuntime = try ModelRuntime(
      id: .init(rawValue: "runtime.terminal-publication.failure"),
      client: TrailingFailureClient(
        providerID: descriptor.providerID,
        modelDescriptor: descriptor))

    for iteration in 0..<500 {
      do {
        _ = try await failingRuntime.generate(Self.request())
        Issue.record("Trailing provider failure unexpectedly passed at iteration \(iteration).")
        return
      } catch let failure as ModelGenerationFailure {
        #expect(failure.code == .transportFailure)
      }
      let phase = await failingRuntime.status().phase
      guard phase == .idle else {
        Issue.record(
          "Failure terminal returned before idle at iteration \(iteration): \(phase)")
        return
      }
    }
  }

  @Test func cancellingGeneratePropagatesTaskCancellationAndCancelsProvider() async throws {
    let descriptor = Self.descriptor()
    let source = ControlledSource()
    let client = ControlledClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor,
      source: source)
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.generate-cancel"),
      client: client)

    let task = Task { try await runtime.generate(Self.request(deadline: .seconds(2))) }
    try await Self.waitUntil { source.isConnected }
    source.yield(.started(descriptor: descriptor))
    task.cancel()

    do {
      _ = try await task.value
      Issue.record("Cancelled generate unexpectedly completed.")
    } catch is CancellationError {
      // Expected: the caller's task cancellation remains distinct from provider failure.
    }
    try await Self.waitUntil { source.wasCancelled }
    try await Self.waitUntil { await runtime.status().phase == .idle }
  }

  @Test func explicitCancellationTerminatesRunAndCancelsProvider() async throws {
    let descriptor = Self.descriptor()
    let source = ControlledSource()
    let client = ControlledClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor,
      source: source)
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.cancel"),
      client: client)

    let run = try await runtime.start(Self.request(deadline: .seconds(2)))
    try await Self.waitUntil { source.isConnected }
    source.yield(.started(descriptor: descriptor))

    let collector = Task { try await Self.collect(run.events) }
    await run.cancel()

    do {
      _ = try await collector.value
      Issue.record("Cancelled run unexpectedly completed.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .cancelled)
    }
    try await Self.waitUntil { source.wasCancelled }
    try await Self.waitUntil { await runtime.status().phase == .idle }
  }

  @Test func explicitCancellationWaitsUntilProviderPumpActuallyDrains() async throws {
    let descriptor = Self.descriptor()
    let source = NonCooperativeSource(descriptor: descriptor)
    let client = NonCooperativeClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor,
      source: source)
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.cancel-drain"),
      client: client)

    let run = try await runtime.start(Self.request(deadline: .seconds(2)))
    let collector = Task { try await Self.collect(run.events) }
    try await Self.waitUntil { source.didEmitStart }

    let completion = CompletionProbe()
    let cancellation = Task {
      await run.cancel()
      completion.record()
    }

    try await Task.sleep(for: .milliseconds(30))
    #expect(!completion.didComplete)
    #expect(await runtime.status().phase == .draining)

    source.release()
    await cancellation.value
    #expect(completion.didComplete)

    do {
      _ = try await collector.value
      Issue.record("Cancelled run unexpectedly completed.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .cancelled)
    }
    try await Self.waitUntil { await runtime.status().phase == .idle }
  }

  @Test func cancellingGenerateWaitsUntilProviderPumpActuallyDrains() async throws {
    let descriptor = Self.descriptor()
    let source = NonCooperativeSource(descriptor: descriptor)
    let client = NonCooperativeClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor,
      source: source)
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.generate-cancel-drain"),
      client: client)

    let completion = CompletionProbe()
    let generation = Task {
      defer { completion.record() }
      _ = try await runtime.generate(Self.request(deadline: .seconds(2)))
    }
    try await Self.waitUntil { source.didEmitStart }

    generation.cancel()
    try await Task.sleep(for: .milliseconds(30))
    #expect(!completion.didComplete)
    #expect(await runtime.status().phase == .draining)

    source.release()
    do {
      _ = try await generation.value
      Issue.record("Cancelled generate unexpectedly completed.")
    } catch is CancellationError {
      // Definitive caller cancellation is returned only after provider drain.
    }
    #expect(completion.didComplete)
    #expect(await runtime.status().phase == .idle)
  }

  @Test func cancelActiveRunWaitsUntilProviderPumpActuallyDrains() async throws {
    let descriptor = Self.descriptor()
    let source = NonCooperativeSource(descriptor: descriptor)
    let client = NonCooperativeClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor,
      source: source)
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.active-cancel-drain"),
      client: client)

    let run = try await runtime.start(Self.request(deadline: .seconds(2)))
    let collector = Task { try await Self.collect(run.events) }
    try await Self.waitUntil { source.didEmitStart }

    let completion = CompletionProbe()
    let cancellation = Task {
      await runtime.cancelActiveRun()
      completion.record()
    }

    try await Task.sleep(for: .milliseconds(30))
    #expect(!completion.didComplete)
    #expect(await runtime.status().phase == .draining)

    source.release()
    await cancellation.value
    #expect(completion.didComplete)

    do {
      _ = try await collector.value
      Issue.record("Cancelled active run unexpectedly completed.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .cancelled)
    }
    #expect(await runtime.status().phase == .idle)
  }

  @Test func deadlineIsEnforcedByRuntimeWithoutFallback() async throws {
    let descriptor = Self.descriptor()
    let source = ControlledSource()
    let client = ControlledClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor,
      source: source)
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.deadline"),
      client: client)

    let run = try await runtime.start(Self.request(deadline: .milliseconds(40)))
    try await Self.waitUntil { source.isConnected }
    source.yield(.started(descriptor: descriptor))

    do {
      _ = try await Self.collect(run.events)
      Issue.record("Deadline-exceeded run unexpectedly completed.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .deadlineExceeded)
    }
    #expect(source.connectionCount == 1)
    try await Self.waitUntil { source.wasCancelled }
  }

  @Test func completedEventIsWithheldUntilProviderEOF() async throws {
    let descriptor = Self.descriptor()
    let client = ScriptedClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor,
      events: [
        .started(descriptor: descriptor),
        .completed(ModelTurn(content: "done")),
        .textDelta("illegal"),
      ])
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.trailing-event"),
      client: client)

    let run = try await runtime.start(Self.request())
    var observed: [ModelEvent] = []
    do {
      for try await event in run.events { observed.append(event) }
      Issue.record("An event after completed unexpectedly passed.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .malformedEvent)
    }
    #expect(observed == [.started(descriptor: descriptor)])
  }

  @Test func completedEventIsWithheldWhenTransportFailsAfterTerminal() async throws {
    let descriptor = Self.descriptor()
    let client = TrailingFailureClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor)
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.trailing-error"),
      client: client)

    let run = try await runtime.start(Self.request())
    var observed: [ModelEvent] = []
    do {
      for try await event in run.events { observed.append(event) }
      Issue.record("A trailing transport failure unexpectedly passed.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .transportFailure)
    }
    #expect(observed == [.started(descriptor: descriptor)])
  }

  @Test func completionWinsAtomicallyOverLaterCancellation() async throws {
    let pair = AsyncThrowingStream<ModelEvent, any Error>.makeStream()
    let control = ModelRunControl(continuation: pair.continuation)
    let terminal = ModelEvent.completed(ModelTurn(content: "done"))
    let publication = CompletionProbe()

    #expect(
      await control.complete(
        with: terminal,
        after: { publication.record() }))
    #expect(publication.didComplete)
    #expect(
      !(await control.finish(
        throwing: ModelGenerationFailure(.cancelled, "late cancellation"),
        after: {})))
    #expect(try await Self.collect(pair.stream) == [terminal])
  }

  @Test func acceptedTerminationWinsOverProviderFailure() async throws {
    let pair = AsyncThrowingStream<ModelEvent, any Error>.makeStream()
    let control = ModelRunControl(continuation: pair.continuation)
    let publication = CompletionProbe()
    let deadline = ModelGenerationFailure(.deadlineExceeded, "deadline won")

    #expect(control.requestTermination(deadline))
    #expect(
      await control.finish(
        throwing: ModelGenerationFailure(.transportFailure, "provider failed"),
        after: { publication.record() }))
    #expect(publication.didComplete)

    do {
      _ = try await Self.collect(pair.stream)
      Issue.record("Accepted deadline was replaced by provider failure.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .deadlineExceeded)
    }
  }

  @Test func cancellingTheConsumerCancelsProviderWork() async throws {
    let descriptor = Self.descriptor()
    let source = ControlledSource()
    let client = ControlledClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor,
      source: source)
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.consumer-cancel"),
      client: client)

    let run = try await runtime.start(Self.request(deadline: .seconds(2)))
    try await Self.waitUntil { source.isConnected }
    source.yield(.started(descriptor: descriptor))

    let consumer = Task {
      var iterator = run.events.makeAsyncIterator()
      _ = try await iterator.next()
      _ = try await iterator.next()
    }
    try await Task.sleep(for: .milliseconds(10))
    consumer.cancel()
    _ = try? await consumer.value

    try await Self.waitUntil { source.wasCancelled }
    try await Self.waitUntil { await runtime.status().phase == .idle }
  }

  @Test func eventCountIsBounded() async throws {
    let descriptor = Self.descriptor()
    let policy = try ModelRuntimePolicy(maximumEventCount: 2)
    let client = ScriptedClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor,
      events: [
        .started(descriptor: descriptor),
        .usage(.init(inputTokens: 1, outputTokens: 1, totalTokens: 2)),
        .completed(ModelTurn(content: "done")),
      ])
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.events"),
      client: client,
      policy: policy)

    let run = try await runtime.start(Self.request())
    do {
      _ = try await Self.collect(run.events)
      Issue.record("Overlong event sequence unexpectedly passed.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .limitExceeded)
    }
  }

  @Test func shutdownIsIdempotentAndRunsCleanupExactlyOnce() async throws {
    let descriptor = Self.descriptor()
    let cleanup = InvocationProbe()
    let client = ScriptedClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor,
      events: [
        .started(descriptor: descriptor),
        .completed(ModelTurn(content: "done")),
      ])
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.shutdown"),
      client: client,
      cleanup: { cleanup.record() })

    let run = try await runtime.start(Self.request())
    _ = try await Self.collect(run.events)
    try await Self.waitUntil { await runtime.status().phase == .idle }

    try await runtime.shutdown()
    try await runtime.shutdown()

    #expect(cleanup.invocations == 1)
    #expect(await runtime.status().phase == .closed)
    do {
      _ = try await runtime.start(Self.request())
      Issue.record("Closed runtime unexpectedly started.")
    } catch let failure as ModelRuntimeFailure {
      #expect(failure.code == .closed)
    }
  }

  @Test func cleanupFailureIsVisibleAndRuntimeBecomesUnusable() async throws {
    let descriptor = Self.descriptor()
    let client = ScriptedClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor,
      events: [])
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.cleanup-failure"),
      client: client,
      cleanup: { throw CleanupError.failed })

    do {
      try await runtime.shutdown()
      Issue.record("Cleanup failure was hidden.")
    } catch let failure as ModelRuntimeFailure {
      #expect(failure.code == .cleanupFailed)
    }
    let status = await runtime.status()
    #expect(status.phase == .failed)
    #expect(status.failure?.code == .cleanupFailed)

    do {
      _ = try await runtime.start(Self.request())
      Issue.record("Failed runtime unexpectedly accepted a new run.")
    } catch let failure as ModelRuntimeFailure {
      #expect(failure.code == .cleanupFailed)
    }
  }

  @Test func shutdownDoesNotPretendSuccessWhenProviderWillNotDrain() async throws {
    let descriptor = Self.descriptor()
    let source = NonCooperativeSource(descriptor: descriptor)
    let cleanup = InvocationProbe()
    let client = NonCooperativeClient(
      providerID: descriptor.providerID,
      modelDescriptor: descriptor,
      source: source)
    let policy = try ModelRuntimePolicy(
      shutdownDrainTimeout: .milliseconds(40),
      drainPollInterval: .milliseconds(5))
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.poison"),
      client: client,
      policy: policy,
      cleanup: { cleanup.record() })

    let run = try await runtime.start(Self.request(deadline: .seconds(2)))
    let collector = Task { try await Self.collect(run.events) }
    try await Self.waitUntil { source.didEmitStart }

    do {
      try await runtime.shutdown()
      Issue.record("Non-draining provider was reported as cleanly shut down.")
    } catch let failure as ModelRuntimeFailure {
      #expect(failure.code == .shutdownDrainTimedOut)
    }
    #expect(cleanup.invocations == 0)
    #expect(await runtime.status().phase == .failed)

    source.release()
    _ = try? await collector.value
  }

  @Test func preCancelledStartDoesNotAcquireRuntimeOrEnterProvider() async throws {
    let descriptor = Self.descriptor()
    let probe = InvocationProbe()
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.precancel"),
      client: CountingClient(providerID: descriptor.providerID, modelDescriptor: descriptor, probe: probe)
    )
    let operation = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      do {
        let run = try await runtime.start(Self.request())
        Issue.record("A pre-cancelled caller started provider work.")
        await run.cancel()
      } catch is CancellationError {
        // No reservation and no provider entry are allowed.
      }
    }
    try await operation.value
    #expect(probe.invocations == 0)
    #expect(await runtime.status().phase == .idle)
  }

  @Test func cancelledReservationStartKeepsTokenReleasable() async throws {
    let descriptor = Self.descriptor()
    let probe = InvocationProbe()
    let runtime = try ModelRuntime(
      id: .init(rawValue: "runtime.cancelled-reservation"),
      client: CountingClient(providerID: descriptor.providerID, modelDescriptor: descriptor, probe: probe)
    )
    let reservation = try await runtime.reserve(Self.request())
    let operation = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      do {
        let run = try await runtime.start(reservation)
        Issue.record("A cancelled caller consumed an existing reservation.")
        await run.cancel()
      } catch is CancellationError {}
    }
    try await operation.value
    #expect(await runtime.release(reservation))
    #expect(probe.invocations == 0)
    #expect(await runtime.status().phase == .idle)
  }

  private static func descriptor(
    id: String = "model-a",
    capabilities: ModelCapabilities = [.textInput, .textOutput, .streaming]
  ) -> ModelDescriptor {
    ModelDescriptor(
      id: id,
      providerID: "provider.test",
      displayName: "Test Model",
      capabilities: capabilities)
  }

  private static func request(
    modelID: String? = "model-a",
    deadline: Duration = .seconds(1)
  ) -> ModelRequest {
    ModelRequest(
      sessionID: "session-1",
      modelID: modelID,
      messages: [.init(role: .user, content: "hello")],
      tools: [],
      requiredCapabilities: [.textInput, .textOutput, .streaming],
      deadline: deadline)
  }

  private static func collect(
    _ stream: AsyncThrowingStream<ModelEvent, any Error>
  ) async throws -> [ModelEvent] {
    var events: [ModelEvent] = []
    for try await event in stream { events.append(event) }
    return events
  }

  private static func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
      guard clock.now < deadline else {
        throw WaitError.timedOut
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}

private enum StartOutcome: Sendable {
  case started(ModelRun)
  case busy
  case unexpected(String)

  var run: ModelRun? {
    guard case .started(let run) = self else { return nil }
    return run
  }

  var isBusy: Bool {
    if case .busy = self { return true }
    return false
  }

  var isUnexpected: Bool {
    if case .unexpected = self { return true }
    return false
  }
}

private struct ScriptedClient: ModelClient {
  let providerID: String
  let modelDescriptor: ModelDescriptor?
  let events: [ModelEvent]

  func generate(request: ModelRequest) async throws -> ModelTurn {
    try await ModelStreamContract.completedTurn(from: stream(request: request), request: request)
  }

  func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
    AsyncThrowingStream { continuation in
      for event in events { continuation.yield(event) }
      continuation.finish()
    }
  }
}

private struct TrailingFailureClient: ModelClient {
  let providerID: String
  let modelDescriptor: ModelDescriptor?

  func generate(request: ModelRequest) async throws -> ModelTurn {
    try await ModelStreamContract.completedTurn(from: stream(request: request), request: request)
  }

  func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(.started(descriptor: modelDescriptor))
      continuation.yield(.completed(ModelTurn(content: "done")))
      continuation.finish(throwing: ProviderError.trailingFailure)
    }
  }
}

private struct ProviderCancellationClient: ModelClient {
  let providerID: String
  let modelDescriptor: ModelDescriptor?

  func generate(request: ModelRequest) async throws -> ModelTurn {
    throw ModelGenerationFailure(.cancelled, "Provider cancelled itself.")
  }

  func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(.started(descriptor: modelDescriptor))
      continuation.finish(
        throwing: ModelGenerationFailure(.cancelled, "Provider cancelled itself."))
    }
  }
}

private struct PreStartFailureClient: ModelClient {
  let providerID: String
  let modelDescriptor: ModelDescriptor?

  func generate(request: ModelRequest) async throws -> ModelTurn {
    throw TypedProviderFailure()
  }

  func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
    AsyncThrowingStream { continuation in
      continuation.finish(throwing: TypedProviderFailure())
    }
  }
}

private struct TypedFailureClient: ModelClient {
  let providerID: String
  let modelDescriptor: ModelDescriptor?

  func generate(request: ModelRequest) async throws -> ModelTurn {
    throw TypedProviderFailure()
  }

  func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(.started(descriptor: modelDescriptor))
      continuation.finish(throwing: TypedProviderFailure())
    }
  }
}

private struct TypedProviderFailure: ModelClientFailure, Equatable {
  var modelFailureCode: String { "provider_rate_limited" }
  var modelFailureDetails: [String: JSONValue] { ["retryAfterSeconds": .integer(7)] }
  var errorDescription: String? { "Provider rate limit reached." }
}

private struct CountingClient: ModelClient {
  let providerID: String
  let modelDescriptor: ModelDescriptor?
  let probe: InvocationProbe

  func generate(request: ModelRequest) async throws -> ModelTurn {
    ModelTurn(content: "unused")
  }

  func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
    probe.record()
    return AsyncThrowingStream { continuation in
      continuation.yield(.started(descriptor: modelDescriptor))
      continuation.yield(.completed(ModelTurn(content: "unused")))
      continuation.finish()
    }
  }
}

private struct ControlledClient: ModelClient {
  let providerID: String
  let modelDescriptor: ModelDescriptor?
  let source: ControlledSource

  func generate(request: ModelRequest) async throws -> ModelTurn {
    try await ModelStreamContract.completedTurn(from: stream(request: request), request: request)
  }

  func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
    source.connect()
  }
}

private final class ControlledSource: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncThrowingStream<ModelEvent, any Error>.Continuation?
  private var cancelled = false
  private var connections = 0

  var isConnected: Bool {
    lock.lock()
    defer { lock.unlock() }
    return continuation != nil
  }

  var wasCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  var connectionCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return connections
  }

  func connect() -> AsyncThrowingStream<ModelEvent, any Error> {
    AsyncThrowingStream { continuation in
      lock.lock()
      self.continuation = continuation
      connections += 1
      lock.unlock()
      continuation.onTermination = { [weak self] termination in
        guard case .cancelled = termination else { return }
        self?.markCancelled()
      }
    }
  }

  func yield(_ event: ModelEvent) {
    lock.lock()
    let continuation = self.continuation
    lock.unlock()
    continuation?.yield(event)
  }

  func finish() {
    lock.lock()
    let continuation = self.continuation
    lock.unlock()
    continuation?.finish()
  }

  private func markCancelled() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}

private final class CompletionProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var completed = false

  var didComplete: Bool {
    lock.lock()
    defer { lock.unlock() }
    return completed
  }

  func record() {
    lock.lock()
    completed = true
    lock.unlock()
  }
}

private struct NonCooperativeClient: ModelClient {
  let providerID: String
  let modelDescriptor: ModelDescriptor?
  let source: NonCooperativeSource

  func generate(request: ModelRequest) async throws -> ModelTurn {
    try await ModelStreamContract.completedTurn(from: stream(request: request), request: request)
  }

  func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
    AsyncThrowingStream(unfolding: { await source.next() })
  }
}

private final class NonCooperativeSource: @unchecked Sendable {
  private let lock = NSLock()
  private let descriptor: ModelDescriptor
  private var index = 0
  private var waiter: CheckedContinuation<ModelEvent?, Never>?
  private var emittedStart = false
  private var released = false

  init(descriptor: ModelDescriptor) {
    self.descriptor = descriptor
  }

  var didEmitStart: Bool {
    lock.lock()
    defer { lock.unlock() }
    return emittedStart
  }

  func next() async -> ModelEvent? {
    switch nextAction() {
    case .value(let event):
      return event
    case .wait:
      return await withCheckedContinuation { continuation in
        lock.lock()
        if released {
          lock.unlock()
          continuation.resume(returning: nil)
        } else {
          waiter = continuation
          lock.unlock()
        }
      }
    }
  }

  private enum NextAction {
    case value(ModelEvent?)
    case wait
  }

  private func nextAction() -> NextAction {
    lock.lock()
    defer { lock.unlock() }
    if index == 0 {
      index = 1
      emittedStart = true
      return .value(.started(descriptor: descriptor))
    }
    if released { return .value(nil) }
    return .wait
  }

  func release() {
    lock.lock()
    released = true
    let waiter = self.waiter
    self.waiter = nil
    lock.unlock()
    waiter?.resume(returning: nil)
  }
}

private final class InvocationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  var invocations: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func record() {
    lock.lock()
    value += 1
    lock.unlock()
  }
}

private enum ProviderError: Error { case trailingFailure }
private enum CleanupError: Error { case failed }
private enum WaitError: Error { case timedOut }

@Suite("ModelProviderRegistry")
struct ModelProviderRegistryTests {
  private struct ProviderClient: ModelClient {
    nonisolated func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        scriptedModelEvents(descriptor: modelDescriptor) { try await self.generate(request: request) }
    }

    let providerID: String
    let modelDescriptor: ModelDescriptor?

    func generate(request: ModelRequest) async throws -> ModelTurn {
      ModelTurn(content: "ok", stopReason: .stop)
    }
  }

  @Test func resolvesOnlyExplicitProviderAndModel() async throws {
    let descriptor = try ModelProviderDescriptor(
      id: "local.test", displayName: "Local Test", kind: .onDevice)
    let model = ModelDescriptor(
      id: "model-a", providerID: descriptor.id, displayName: "A", capabilities: .textOnly)
    let connector = ClosureModelProviderConnector(
      descriptor: descriptor,
      availability: { .available },
      models: { [model] },
      acquireRuntime: { modelID in guard modelID == nil || modelID == model.id else {
          throw ModelGenerationFailure(.invalidRequest, "unknown model")
        }
        return .owned(try ModelRuntime(
          id: ModelRuntimeID(rawValue: "local.test.runtime"),
          client: ProviderClient(providerID: descriptor.id, modelDescriptor: model),
          descriptor: model
        )) }
    )
    let registry = try ModelProviderRegistry([connector])

    let providers = await registry.providers()
    #expect(providers == [descriptor])
    let models = try await registry.models(providerID: descriptor.id)
    #expect(models == [model])
    let access = try await registry.acquireRuntime(
      ModelProviderSelection(providerID: descriptor.id, modelID: model.id))
    #expect(access.runtime.providerID == descriptor.id)
    #expect(access.runtime.modelDescriptor.id == model.id)
    try await access.release()
  }

  @Test func rejectedRuntimeIsShutdownBeforeRegistryThrows() async throws {
    let descriptor = try ModelProviderDescriptor(
      id: "expected.provider", displayName: "Expected", kind: .onDevice)
    let wrongModel = ModelDescriptor(
      id: "model-a", providerID: "wrong.provider", displayName: "Wrong", capabilities: .textOnly)
    let cleanup = InvocationProbe()
    let connector = ClosureModelProviderConnector(
      descriptor: descriptor,
      availability: { .available },
      models: { [] },
      acquireRuntime: { _ in .owned(try ModelRuntime(
          id: ModelRuntimeID(rawValue: "wrong.runtime"),
          client: ProviderClient(providerID: wrongModel.providerID, modelDescriptor: wrongModel),
          descriptor: wrongModel,
          cleanup: { cleanup.record() }
        )) }
    )
    let registry = try ModelProviderRegistry([connector])

    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await registry.acquireRuntime(
        ModelProviderSelection(providerID: descriptor.id)
      )
    }
    #expect(cleanup.invocations == 1)
  }

  @Test func doesNotFallbackWhenSelectedProviderNeedsAuthentication() async throws {
    let descriptor = try ModelProviderDescriptor(
      id: "remote.test", displayName: "Remote Test", kind: .remote)
    let connector = ClosureModelProviderConnector(
      descriptor: descriptor,
      availability: { .authenticationRequired },
      models: { [] },
      acquireRuntime: { _ in
        Issue.record("runtime must not be created before authentication")
        throw ModelGenerationFailure(.sourceUnavailable, "unreachable")
      }
    )
    let registry = try ModelProviderRegistry([connector])

    do {
      _ = try await registry.acquireRuntime(ModelProviderSelection(providerID: descriptor.id))
      Issue.record("expected authentication failure")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .authenticationRequired)
    }
  }
}
