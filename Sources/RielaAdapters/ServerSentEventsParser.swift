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

public final class ServerSentEventsParser {
  private var isAtStreamStart = true
  private var pendingCarriageReturn = false
  private var pendingBytes = Data()
  private var currentLine = ""
  private var dataLines: [String] = []
  private var eventName: String?
  private var lastEventId: String?

  public init() {}

  public func feed(_ chunk: Data) -> [ServerSentEvent] {
    guard !chunk.isEmpty else {
      return []
    }

    pendingBytes.append(chunk)
    guard var text = String(data: pendingBytes, encoding: .utf8) else {
      return []
    }
    pendingBytes.removeAll(keepingCapacity: true)
    if isAtStreamStart {
      isAtStreamStart = false
      if text.first == "\u{FEFF}" {
        text.removeFirst()
      }
    }

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

  public func finish() -> [ServerSentEvent] {
    let eventsFromPendingBytes: [ServerSentEvent]
    if !pendingBytes.isEmpty, let text = String(data: pendingBytes, encoding: .utf8) {
      pendingBytes.removeAll(keepingCapacity: true)
      eventsFromPendingBytes = feed(Data(text.utf8))
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
