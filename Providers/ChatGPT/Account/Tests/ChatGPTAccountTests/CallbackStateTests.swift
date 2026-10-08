import Foundation
import Testing
@testable import ChatGPTAccount

private final class CallbackConnection: Sendable {}

@Test func callbackShutdownRequiresListenerAndEveryAcceptedConnection() {
  var state = ChatGPTCallbackState<CallbackConnection>()
  #expect({ state.start() }())
  #expect({ state.ready() }())
  let first = CallbackConnection(), second = CallbackConnection()
  #expect({ state.track(first) }())
  #expect({ state.track(second) }())
  #expect({ state.stopListener() }())
  #expect({ state.cancelConnections().count == 2 }())
  state.listenerCancelled()
  #expect(!state.isDrained)
  state.connectionCancelled(first)
  #expect(!state.isDrained)
  state.connectionCancelled(second)
  #expect(state.isDrained)
  #expect(state.connectionCount == 0)
}

@Test(arguments: [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]])
func callbackDrainIsIndependentOfReceiptOrder(order: [Int]) {
  var state = ChatGPTCallbackState<CallbackConnection>()
  let connection = CallbackConnection(), operation = UUID()
  #expect({ state.start() }())
  #expect({ state.ready() }())
  #expect({ state.track(connection) }())
  #expect({ state.beginIO(on: connection, id: operation) }())
  #expect({ state.stopListener() }())
  #expect({ state.cancelConnections().count == 1 }())
  for (offset, receipt) in order.enumerated() {
    switch receipt {
    case 0: state.listenerCancelled()
    case 1: state.connectionCancelled(connection)
    default:
      #expect({ state.completeIO(on: connection, id: operation) }())
    }
    #expect(state.isDrained == (offset == order.count - 1))
  }
}

@Test func callbackDuplicateAndStaleIOCannotSettleNewReceive() {
  var state = ChatGPTCallbackState<CallbackConnection>()
  let connection = CallbackConnection(), old = UUID(), current = UUID()
  #expect({ state.start() }())
  #expect({ state.ready() }())
  #expect({ state.track(connection) }())
  #expect({ state.beginIO(on: connection, id: old) }())
  #expect({ state.completeIO(on: connection, id: old) }())
  #expect({ state.beginIO(on: connection, id: current) }())
  #expect({ !state.completeIO(on: connection, id: old) }())
  #expect({ state.stopListener() }())
  state.listenerCancelled()
  state.connectionCancelled(connection)
  #expect(!state.isDrained)
  #expect({ state.completeIO(on: connection, id: current) }())
  #expect(state.isDrained)
  #expect({ !state.completeIO(on: connection, id: current) }())
}

@Test func callbackCancelledReadCannotSubmitAnotherReadOrResponse() {
  var state = ChatGPTCallbackState<CallbackConnection>()
  let connection = CallbackConnection(), read = UUID()
  #expect({ state.start() }())
  #expect({ state.ready() }())
  #expect({ state.track(connection) }())
  #expect({ state.beginIO(on: connection, id: read) }())
  #expect({ state.cancel(connection) === connection }())
  #expect({ state.completeIO(on: connection, id: read) }())
  #expect({ !state.beginIO(on: connection, id: UUID()) }())
  #expect({ !state.beginIO(on: connection, id: UUID(), response: true) }())
  #expect({ state.cancel(connection) == nil }())
}

@Test func callbackSelectedResponseIsRetainedWhileOtherConnectionsAreCancelled() {
  var state = ChatGPTCallbackState<CallbackConnection>()
  let selected = CallbackConnection(), stalled = CallbackConnection(), write = UUID()
  #expect({ state.start() }())
  #expect({ state.ready() }())
  #expect({ state.track(selected) }())
  #expect({ state.track(stalled) }())
  #expect({ state.beginIO(on: selected, id: write, response: true) }())
  #expect({ state.stopListener() }())
  let cancelled = state.cancelConnections(preserving: selected)
  #expect(cancelled.count == 1 && cancelled.first === stalled)
  state.connectionCancelled(stalled)
  state.listenerCancelled()
  #expect(!state.isDrained)
  #expect({ state.completeIO(on: selected, id: write) }())
  #expect({ state.cancel(selected) === selected }())
  #expect(!state.isDrained)
  state.connectionCancelled(selected)
  #expect(state.isDrained)
}

@Test func callbackRejectedConnectionDuringShutdownIsStillOwned() {
  var state = ChatGPTCallbackState<CallbackConnection>()
  #expect({ state.start() }())
  #expect({ state.ready() }())
  #expect({ state.stopListener() }())
  let late = CallbackConnection()
  #expect({ state.track(late) }())
  #expect({ !state.beginIO(on: late, id: UUID()) }())
  #expect({ state.cancel(late) === late }())
  state.listenerCancelled()
  #expect(!state.isDrained)
  state.connectionCancelled(late)
  #expect(state.isDrained)
}

@Test func callbackResourceLivesUntilItsLastReceipt() {
  var state = ChatGPTCallbackState<CallbackConnection>()
  #expect({ state.start() }())
  #expect({ state.ready() }())
  var connection: CallbackConnection? = CallbackConnection()
  weak let probe = connection
  #expect({ state.track(connection!) }())
  let operation = UUID()
  #expect({ state.beginIO(on: connection!, id: operation) }())
  #expect({ state.stopListener() }())
  state.listenerCancelled()
  state.connectionCancelled(connection!)
  connection = nil
  #expect(probe != nil)
  #expect(!state.isDrained)
  #expect({ state.completeIO(on: probe!, id: operation) }())
  #expect(probe == nil)
  #expect(state.isDrained)
}

@Test func callbackLifecycleIsOneShotAndUnusedCancelHasNoNativeReceipt() {
  var state = ChatGPTCallbackState<CallbackConnection>()
  #expect({ !state.ready() }())
  #expect({ !state.track(CallbackConnection()) }())
  #expect({ !state.stopListener() }())
  #expect(state.isDrained)
  #expect({ !state.start() }())
  #expect({ !state.track(CallbackConnection()) }())
  state.listenerCancelled()
  #expect(state.isDrained)
}

@Test func callbackDuplicateReadyCancelAndConnectionReceiptsAreIdempotent() {
  var state = ChatGPTCallbackState<CallbackConnection>()
  let connection = CallbackConnection()
  #expect({ state.start() }())
  #expect({ !state.start() }())
  #expect({ state.ready() }())
  #expect({ !state.ready() }())
  #expect({ state.track(connection) }())
  #expect({ !state.track(connection) }())
  #expect({ state.stopListener() }())
  #expect({ !state.stopListener() }())
  #expect({ !state.ready() }())
  #expect({ state.cancelConnections().count == 1 }())
  #expect({ state.cancelConnections().isEmpty }())
  state.listenerCancelled()
  state.listenerCancelled()
  state.connectionCancelled(connection)
  state.connectionCancelled(connection)
  #expect(state.isDrained)
}

@Test func callbackRejectsConcurrentAndPostResponseIO() {
  var state = ChatGPTCallbackState<CallbackConnection>()
  let connection = CallbackConnection(), read = UUID(), write = UUID()
  #expect({ state.start() }())
  #expect({ state.ready() }())
  #expect({ state.track(connection) }())
  #expect({ state.beginIO(on: connection, id: read) }())
  #expect({ !state.beginIO(on: connection, id: UUID()) }())
  #expect({ !state.beginIO(on: connection, id: write, response: true) }())
  #expect({ state.completeIO(on: connection, id: read) }())
  #expect({ state.beginIO(on: connection, id: write, response: true) }())
  #expect({ !state.beginIO(on: connection, id: UUID()) }())
  #expect({ state.completeIO(on: connection, id: write) }())
  #expect({ !state.beginIO(on: connection, id: UUID()) }())
  #expect({ !state.beginIO(on: connection, id: UUID(), response: true) }())
  #expect({ state.stopListener() }())
  #expect({ state.cancel(connection) === connection }())
  state.connectionCancelled(connection)
  #expect(!state.isDrained)
  state.listenerCancelled()
  #expect(state.isDrained)
}
