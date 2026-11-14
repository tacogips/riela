import Foundation
import RielaCore

struct BackendEventBridge: Sendable {
  var handler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?
  /// Injects a synthesized event (tool-child recovery diagnostics) into the
  /// same consumer stream as classified stdout events.
  var emitInjected: @Sendable (AdapterBackendEvent) -> Void
  var finish: @Sendable () -> Void
  var waitForCompletion: @Sendable () async -> Void
}

func fallbackBackendEvent(command: LocalAgentCommand, line: String) -> AdapterBackendEvent? {
  guard let eventType = command.backendEventType(line) else {
    return nil
  }
  return AdapterBackendEvent(provider: command.provider, eventType: eventType)
}

func sanitizedBackendEventContent(_ text: String?, sensitiveValues: [String]) -> String? {
  guard let text else {
    return nil
  }
  let redacted = redactAdapterSensitiveText(text, additionalSensitiveValues: sensitiveValues)
  let cap = 16 * 1024
  guard redacted.utf8.count > cap else {
    return redacted
  }
  var prefix = ""
  prefix.reserveCapacity(cap)
  for character in redacted {
    guard prefix.utf8.count + String(character).utf8.count <= cap else {
      break
    }
    prefix.append(character)
  }
  return prefix
}

func backendContentStreamingEnabled(_ value: JSONValue?) -> Bool {
  guard case let .bool(enabled) = value else {
    return true
  }
  return enabled
}
