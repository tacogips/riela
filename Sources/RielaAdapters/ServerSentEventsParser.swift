import Foundation

public struct ServerSentEvent: Equatable, Sendable {
  public var id: String?
  public var event: String?
  public var data: String

  public init(id: String? = nil, event: String? = nil, data: String) {
    self.id = id
    self.event = event
    self.data = data
  }
}

public enum ServerSentEventsParserError: Error, Equatable, Sendable {
  case pendingBufferLimitExceeded(maxBytes: Int)
}

public final class ServerSentEventsParser {
  private static let maxPendingBytes = 1_048_576

  private var isAtStreamStart = true
  private var pendingCarriageReturn = false
  private var pendingBytes = Data()
  private var currentLine = ""
  private var dataLines: [String] = []
  private var eventName: String?
  private var lastEventId: String?

  public init() {}

  public func feed(_ chunk: Data) throws -> [ServerSentEvent] {
    guard !chunk.isEmpty else {
      return []
    }

    pendingBytes.append(chunk)
    guard pendingBytes.count <= Self.maxPendingBytes else {
      throw ServerSentEventsParserError.pendingBufferLimitExceeded(maxBytes: Self.maxPendingBytes)
    }
    guard var text = decodePendingText(flushIncompleteScalar: false) else {
      return []
    }
    if isAtStreamStart {
      isAtStreamStart = false
      if text.first == "\u{FEFF}" {
        text.removeFirst()
      }
    }

    return processText(text)
  }

  public func finish() throws -> [ServerSentEvent] {
    let eventsFromPendingBytes: [ServerSentEvent]
    if !pendingBytes.isEmpty, let text = decodePendingText(flushIncompleteScalar: true) {
      pendingBytes.removeAll(keepingCapacity: true)
      eventsFromPendingBytes = processText(text)
    } else {
      pendingBytes.removeAll(keepingCapacity: true)
      eventsFromPendingBytes = []
    }
    pendingCarriageReturn = false
    var events = eventsFromPendingBytes
    if !currentLine.isEmpty {
      events += processLine(currentLine)
      currentLine.removeAll(keepingCapacity: true)
    }
    events += dispatchEventIfNeeded()
    return events
  }

  private func decodePendingText(flushIncompleteScalar: Bool) -> String? {
    guard !pendingBytes.isEmpty else {
      return nil
    }
    if flushIncompleteScalar {
      // swiftlint:disable:next optional_data_string_conversion
      return String(decoding: pendingBytes, as: UTF8.self)
    }
    let suffixLength = trailingIncompleteUTF8SequenceLength(pendingBytes)
    let prefixCount = pendingBytes.count - suffixLength
    guard prefixCount > 0 else {
      return nil
    }
    let prefix = pendingBytes.prefix(prefixCount)
    pendingBytes = Data(pendingBytes.suffix(suffixLength))
    // swiftlint:disable:next optional_data_string_conversion
    return String(decoding: prefix, as: UTF8.self)
  }

  private func processText(_ text: String) -> [ServerSentEvent] {
    var events: [ServerSentEvent] = []
    for scalar in text.unicodeScalars {
      if pendingCarriageReturn {
        pendingCarriageReturn = false
        guard scalar.value != 10 else {
          continue
        }
      }

      switch scalar.value {
      case 13:
        events += processCompleteLine()
        pendingCarriageReturn = true
      case 10:
        events += processCompleteLine()
      default:
        currentLine.append(String(scalar))
      }
    }
    return events
  }

  private func processCompleteLine() -> [ServerSentEvent] {
    let line = currentLine
    currentLine.removeAll(keepingCapacity: true)
    return processLine(line)
  }

  private func processLine(_ line: String) -> [ServerSentEvent] {
    guard !line.isEmpty else {
      return dispatchEventIfNeeded()
    }
    guard line.first != ":" else {
      return []
    }

    let field: String
    var value: String
    if let colonIndex = line.firstIndex(of: ":") {
      field = String(line[..<colonIndex])
      value = String(line[line.index(after: colonIndex)...])
      if value.first == " " {
        value.removeFirst()
      }
    } else {
      field = line
      value = ""
    }

    switch field {
    case "data":
      dataLines.append(value)
    case "event":
      eventName = value
    case "id" where !value.contains("\u{0}"):
      lastEventId = value
    default:
      break
    }

    return []
  }

  private func dispatchEventIfNeeded() -> [ServerSentEvent] {
    guard !dataLines.isEmpty else {
      eventName = nil
      return []
    }
    let event = ServerSentEvent(
      id: lastEventId,
      event: eventName,
      data: dataLines.joined(separator: "\n")
    )
    dataLines.removeAll(keepingCapacity: true)
    eventName = nil
    return [event]
  }
}

private func trailingIncompleteUTF8SequenceLength(_ data: Data) -> Int {
  guard let last = data.last else {
    return 0
  }
  if last < 0x80 {
    return 0
  }
  let bytes = Array(data.suffix(4))
  var continuationCount = 0
  for byte in bytes.reversed() {
    if (0x80...0xBF).contains(byte) {
      continuationCount += 1
      continue
    }
    let expectedLength: Int
    switch byte {
    case 0xC2...0xDF:
      expectedLength = 2
    case 0xE0...0xEF:
      expectedLength = 3
    case 0xF0...0xF4:
      expectedLength = 4
    default:
      return 0
    }
    let actualLength = continuationCount + 1
    return actualLength < expectedLength ? actualLength : 0
  }
  return 0
}
