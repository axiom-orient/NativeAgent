import Foundation

struct ChatGPTSSEEvent: Sendable, Equatable {
  let data: String
}

struct ChatGPTSSEParser: Sendable {
  static let minimumEventBytes = 1
  static let supportedMaximumEventBytes = 256 * 1_024
  static let standardMaximumEvents = 4_096
  static let supportedMaximumEvents = 100_000

  private var lineBuffer = [UInt8]()
  private var dataLines = [String]()
  private var frameBytes = 0
  private var lastLineEndingLength = 0
  private var sawCR = false
  private var ignoreNextLF = false
  private var bomBuffer = [UInt8]()
  private var didResolveBOM = false
  private var emittedEvents = 0
  let maxEventBytes: Int
  let maxEvents: Int

  init(maxEventBytes: Int, maxEvents: Int = Self.standardMaximumEvents) throws {
    guard (Self.minimumEventBytes...Self.supportedMaximumEventBytes).contains(maxEventBytes),
      (1...Self.supportedMaximumEvents).contains(maxEvents)
    else {
      throw ChatGPTWireError.limitExceeded
    }
    self.maxEventBytes = maxEventBytes
    self.maxEvents = maxEvents
  }

  mutating func feed(_ data: Data, finish: Bool = false) throws -> [ChatGPTSSEEvent] {
    var events: [ChatGPTSSEEvent] = []
    for byte in data {
      try consume(byte, to: &events)
    }

    if finish {
      // WHATWG SSE discards an event that has not ended with a blank line.
      // An incomplete BOM is invalid under the subscription's strict UTF-8 contract.
      if !didResolveBOM, !bomBuffer.isEmpty {
        throw ChatGPTWireError.malformedSSE
      }
      lineBuffer.removeAll(keepingCapacity: true)
      bomBuffer.removeAll(keepingCapacity: true)
      resetEvent()
      sawCR = false
      ignoreNextLF = false
    }
    return events
  }

  private mutating func append(_ event: ChatGPTSSEEvent, to events: inout [ChatGPTSSEEvent])
    throws
  {
    emittedEvents += 1
    guard emittedEvents <= maxEvents else { throw ChatGPTWireError.tooManyEvents }
    events.append(event)
  }

  private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

  private mutating func consume(
    _ byte: UInt8,
    to events: inout [ChatGPTSSEEvent]
  ) throws {
    if !didResolveBOM {
      bomBuffer.append(byte)
      if Self.utf8BOM.starts(with: bomBuffer) {
        if bomBuffer.count == Self.utf8BOM.count {
          bomBuffer.removeAll(keepingCapacity: true)
          didResolveBOM = true
        }
        return
      }

      didResolveBOM = true
      let pending = bomBuffer
      bomBuffer.removeAll(keepingCapacity: true)
      for pendingByte in pending {
        try consumeResolved(pendingByte, to: &events)
      }
      return
    }
    try consumeResolved(byte, to: &events)
  }

  private mutating func consumeResolved(
    _ byte: UInt8,
    to events: inout [ChatGPTSSEEvent]
  ) throws {
    switch byte {
    case 0x0A:
      if sawCR {
        sawCR = false
        if ignoreNextLF {
          ignoreNextLF = false
        } else {
          try countFrameByte()
          lastLineEndingLength = 2
        }
      } else {
        try countFrameByte()
        try processLine(endingLength: 1, to: &events)
      }
    case 0x0D:
      // A CR terminates a line immediately. If the next byte is LF, that LF
      // is consumed as part of the same CRLF terminator.
      sawCR = false
      ignoreNextLF = false
      try countFrameByte()
      let lineWasEmpty = lineBuffer.isEmpty
      try processLine(endingLength: 1, to: &events)
      sawCR = true
      ignoreNextLF = lineWasEmpty
    default:
      sawCR = false
      ignoreNextLF = false
      try countFrameByte()
      lineBuffer.append(byte)
    }
  }

  private mutating func countFrameByte() throws {
    let (next, overflow) = frameBytes.addingReportingOverflow(1)
    guard !overflow, next <= maxEventBytes + 4 else {
      throw ChatGPTWireError.responseTooLarge
    }
    frameBytes = next
  }

  private mutating func processLine(
    endingLength: Int,
    to events: inout [ChatGPTSSEEvent]
  ) throws {
    guard let line = String(data: Data(lineBuffer), encoding: .utf8), !line.contains("\0") else {
      throw ChatGPTWireError.malformedSSE
    }

    lineBuffer.removeAll(keepingCapacity: true)
    if line.isEmpty {
      let delimiterBytes = lastLineEndingLength + endingLength
      guard frameBytes >= delimiterBytes,
        frameBytes - delimiterBytes <= maxEventBytes
      else {
        throw ChatGPTWireError.responseTooLarge
      }
      let data = dataLines.joined(separator: "\n")
      if !data.isEmpty {
        try append(ChatGPTSSEEvent(data: data), to: &events)
      }
      resetEvent()
      return
    }

    if !line.hasPrefix(":") {
      let field: String
      var value = ""
      if let colon = line.firstIndex(of: ":") {
        field = String(line[..<colon])
        value = String(line[line.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }
      } else {
        field = line
      }
      switch field {
      case "data": dataLines.append(value)
      case "event", "id", "retry": break
      default: break
      }
    }
    lastLineEndingLength = endingLength
  }

  private mutating func resetEvent() {
    dataLines.removeAll(keepingCapacity: true)
    frameBytes = 0
    lastLineEndingLength = 0
  }
}
