import Foundation
import RielaCore

public struct RetryPolicy: Equatable, Sendable {
  public var maxAttempts: Int
  public var retryDelay: Duration

  public init(maxAttempts: Int = 2, retryDelay: Duration = .milliseconds(50)) {
    self.maxAttempts = max(1, maxAttempts)
    self.retryDelay = retryDelay < .zero ? .zero : retryDelay
  }
}

public func buildCombinedPromptText(promptText: String, systemPromptText: String?) -> String {
  guard let systemPromptText, !systemPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    return promptText
  }
  return "\(systemPromptText)\n\n\(promptText)"
}

public func resolveAdapterImagePaths(_ input: AdapterExecutionInput) -> [String] {
  if case .bool(false) = input.node.variables["forwardImageAttachments"] {
    return []
  }

  var paths: [String] = []
  collectImagePathCandidates(value: .object(input.mergedVariables), paths: &paths)
  collectImagePathCandidates(value: .object(input.arguments), paths: &paths)

  var seen = Set<String>()
  return paths.filter { path in
    guard !path.isEmpty, !seen.contains(path) else {
      return false
    }
    seen.insert(path)
    return true
  }
}

public func resolveNodeExecutionBackend(_ node: AgentNodePayload) throws -> NodeExecutionBackend {
  guard let executionBackend = node.executionBackend else {
    throw AdapterExecutionError(.providerError, "node '\(node.id)' requires explicit executionBackend")
  }
  return executionBackend
}

public func mergedAgentProcessEnvironment(
  baseEnvironment: [String: String],
  input: AdapterExecutionInput,
  provider: String
) -> [String: String] {
  var environment = baseEnvironment.merging(input.agentEnvironment) { _, nodeValue in nodeValue }
  environment["RIELA_AGENT_BACKEND"] = provider
  return environment
}

public func defaultAgentPreflightDeadline(existingDeadline: Date?, timeout: TimeInterval, now: Date = Date()) -> Date {
  let timeoutDeadline = now.addingTimeInterval(max(0, timeout))
  guard let existingDeadline else {
    return timeoutDeadline
  }
  return existingDeadline < timeoutDeadline ? existingDeadline : timeoutDeadline
}

public func agentPreflightErrorDetail(
  _ error: Error,
  fallback: String,
  additionalSensitiveValues: [String] = []
) -> String {
  if error is CancellationError {
    return "preflight cancelled"
  }
  if let error = error as? AdapterExecutionError {
    return redactAdapterSensitiveText(
      error.message.isEmpty ? fallback : error.message,
      additionalSensitiveValues: additionalSensitiveValues
    )
  }
  let message = error.localizedDescription.isEmpty ? fallback : error.localizedDescription
  return redactAdapterSensitiveText(message, additionalSensitiveValues: additionalSensitiveValues)
}

public func rethrowIfCancellation(_ error: Error) throws {
  if let error = error as? CancellationError {
    throw error
  }
}

public func executeWithRetry<T: Sendable>(
  policy: RetryPolicy,
  deadline: Date? = nil,
  now: @Sendable () -> Date = { Date() },
  operation: @Sendable () async throws -> T,
  normalizeError: @Sendable (Error) -> AdapterExecutionError
) async throws -> T {
  var attempt = 1
  while true {
    do {
      return try await operation()
    } catch {
      try rethrowIfCancellation(error)
      let normalized = normalizeError(error)
      if !shouldRetryAdapterFailure(normalized, attempt: attempt, policy: policy, deadline: deadline, now: now()) {
        throw normalized
      }
    }

    attempt += 1
    try await Task.sleep(for: policy.retryDelay)
  }
}

private func shouldRetryAdapterFailure(
  _ error: AdapterExecutionError,
  attempt: Int,
  policy: RetryPolicy,
  deadline: Date?,
  now: Date
) -> Bool {
  guard attempt < policy.maxAttempts, error.code == .providerError || error.code == .timeout else {
    return false
  }
  guard let deadline else {
    return true
  }
  guard error.code != .timeout else {
    return false
  }
  return deadline > now.addingTimeInterval(timeInterval(for: policy.retryDelay))
}

private func timeInterval(for duration: Duration) -> TimeInterval {
  let components = duration.components
  let seconds = TimeInterval(components.seconds)
  let fractionalSeconds = TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
  return max(0, seconds + fractionalSeconds)
}

public func normalizeAdapterFailure(_ error: Error, fallbackMessage: String) -> AdapterExecutionError {
  if let error = error as? AdapterExecutionError {
    return AdapterExecutionError(error.code, redactAdapterSensitiveText(error.message))
  }
  let message = error.localizedDescription.isEmpty ? fallbackMessage : error.localizedDescription
  return AdapterExecutionError(.providerError, redactAdapterSensitiveText(message))
}

private func collectImagePathCandidates(
  value: JSONValue,
  paths: inout [String],
  depth: Int = 0,
  key: String? = nil
) {
  guard depth <= 8 else {
    return
  }

  switch value {
  case let .array(entries):
    if key == "imagePaths" {
      for entry in entries {
        if case let .string(path) = entry, !path.isEmpty {
          paths.append(path)
        }
      }
    }
    for entry in entries {
      collectImagePathCandidates(value: entry, paths: &paths, depth: depth + 1)
    }

  case let .object(object):
    if let imagePaths = object["imagePaths"] {
      collectImagePathCandidates(value: imagePaths, paths: &paths, depth: depth + 1, key: "imagePaths")
    }
    if isImageDescriptor(object) {
      appendImageDescriptorPaths(object, paths: &paths)
    }
    for key in object.keys.sorted() where key != "imagePaths" {
      if let child = object[key] {
        collectImagePathCandidates(value: child, paths: &paths, depth: depth + 1, key: key)
      }
    }

  case .null, .bool, .integer, .number, .string:
    return
  }
}

private func isImageDescriptor(_ object: JSONObject) -> Bool {
  if case let .string(kind) = object["kind"], ["image", "photo", "picture", "screenshot"].contains(kind.lowercased()) {
    return true
  }
  return ["mediaType", "contentType", "mimetype", "mimeType"].contains { key in
    guard case let .string(value) = object[key] else {
      return false
    }
    return value.hasPrefix("image/")
  }
}

private func appendImageDescriptorPaths(_ object: JSONObject, paths: inout [String]) {
  for key in ["path", "localPath", "imagePath", "downloadPath"] {
    if case let .string(path) = object[key], !path.isEmpty {
      paths.append(path)
    }
  }
  guard case let .object(source) = object["source"] else {
    return
  }
  for key in ["path", "localPath", "imagePath", "downloadPath"] {
    if case let .string(path) = source[key], !path.isEmpty {
      paths.append(path)
    }
  }
}

public func redactAdapterSensitiveText(_ text: String, additionalSensitiveValues: [String] = []) -> String {
  var redacted = text

  redacted = replacingRegexMatches(
    in: redacted,
    pattern: #"\b([A-Za-z0-9_]*(?:API[_-]?KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|PRIVATE[_-]?KEY|ACCESS[_-]?KEY)[A-Za-z0-9_]*)\s*[:=]\s*("[^"]*"|'[^']*'|[^\s,;]+)"#,
    options: [.caseInsensitive],
    replacement: #"$1=<redacted>"#
  )
  redacted = replacingRegexMatches(
    in: redacted,
    pattern: #"\bsk-[A-Za-z0-9_-]{8,}\b"#,
    replacement: "<redacted-token>"
  )
  redacted = replacingRegexMatches(
    in: redacted,
    pattern: #"\b(?:Bearer|Token)\s+[A-Za-z0-9._~+/=-]{16,}\b"#,
    replacement: "<redacted-token>"
  )

  for (key, value) in ProcessInfo.processInfo.environment where isSensitiveEnvironmentKey(key) && value.count >= 8 {
    redacted = redacted.replacingOccurrences(of: value, with: "<redacted>")
  }
  for value in additionalSensitiveValues.filter({ $0.count >= 4 }).sorted(by: { $0.count > $1.count }) {
    redacted = redacted.replacingOccurrences(of: value, with: "<redacted>")
  }

  return redacted
}

public func sensitiveAdapterEnvironmentValues(_ environment: [String: String]) -> [String] {
  environment.compactMap { key, value in
    guard isSensitiveAdapterEnvironmentKey(key), value.count >= 4 else {
      return nil
    }
    return value
  }
}

private func isSensitiveEnvironmentKey(_ key: String) -> Bool {
  let normalized = key.uppercased()
  return [
    "API_KEY",
    "APIKEY",
    "TOKEN",
    "SECRET",
    "PASSWORD",
    "PASSWD",
    "CREDENTIAL",
    "PRIVATE_KEY",
    "ACCESS_KEY"
  ].contains { normalized.contains($0) }
}

private func isSensitiveAdapterEnvironmentKey(_ key: String) -> Bool {
  let normalized = key.uppercased()
  if isSensitiveEnvironmentKey(normalized) {
    return true
  }
  return ["CODEX_HOME", "CLAUDE_CONFIG_DIR", "CURSOR_CONFIG_DIR"].contains(normalized)
    || normalized.hasSuffix("_CONFIG_DIR")
}

private func replacingRegexMatches(
  in text: String,
  pattern: String,
  options: NSRegularExpression.Options = [],
  replacement: String
) -> String {
  guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
    return text
  }
  let range = NSRange(text.startIndex..<text.endIndex, in: text)
  return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
}
