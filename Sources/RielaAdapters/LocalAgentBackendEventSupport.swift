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

func commandSensitiveValues(_ command: LocalAgentCommand) -> [String] {
  sensitiveAdapterEnvironmentValues(command.configuration.environment) + command.additionalSensitiveValues
}
func redactedCommandExecutionError(_ error: Error, command: LocalAgentCommand) -> Error {
  if error is CancellationError {
    return error
  }
  let sensitiveValues = commandSensitiveValues(command)
  if let adapterError = error as? AdapterExecutionError {
    return AdapterExecutionError(
      adapterError.code,
      redactAdapterSensitiveText(adapterError.message, additionalSensitiveValues: sensitiveValues),
      isRetryable: adapterError.isRetryable,
      retryAfter: adapterError.retryAfter
    )
  }
  let message = error.localizedDescription
  let redactedMessage = redactAdapterSensitiveText(message, additionalSensitiveValues: sensitiveValues)
  guard redactedMessage != message else {
    return error
  }
  return AdapterExecutionError(.providerError, redactedMessage)
}
func sanitizedBackendEvent(
  _ event: AdapterBackendEvent,
  sensitiveValues: [String]
) -> AdapterBackendEvent {
  var event = event
  event.provider = redactAdapterSensitiveText(event.provider, additionalSensitiveValues: sensitiveValues)
  event.eventType = redactAdapterSensitiveText(event.eventType, additionalSensitiveValues: sensitiveValues)
  event.contentDelta = sanitizedBackendEventContent(event.contentDelta, sensitiveValues: sensitiveValues)
  event.contentSnapshot = sanitizedBackendEventContent(event.contentSnapshot, sensitiveValues: sensitiveValues)
  event.toolName = event.toolName.map {
    redactAdapterSensitiveText($0, additionalSensitiveValues: sensitiveValues)
  }
  event.usage = event.usage.map { sanitizedJSONObject($0, sensitiveValues: sensitiveValues) }
  event.metadata = event.metadata.map { sanitizedJSONObject($0, sensitiveValues: sensitiveValues) }
  return event
}
func sanitizedJSONObject(_ object: JSONObject, sensitiveValues: [String]) -> JSONObject {
  guard case let .object(redacted) = redactAdapterSensitiveJSONValue(
    .object(object),
    additionalSensitiveValues: sensitiveValues
  ) else {
    return [:]
  }
  return redacted
}
func sanitizedWhen(_ when: [String: Bool], sensitiveValues: [String]) -> [String: Bool] {
  var redacted: [String: Bool] = [:]
  for (key, value) in when {
    redacted[redactAdapterSensitiveText(key, additionalSensitiveValues: sensitiveValues)] = value
  }
  return redacted
}
