import Foundation
import RielaCore

/// Retains finite machine diagnostics only. Provider text and arbitrary extensions never leave the reader boundary.
enum GatewayFailureDiagnostics {
  private static let codes: Set<String> = [
    "VALIDATION_ERROR", "AUTH_MISSING", "AUTH_INVALID", "AUTH_EXPIRED", "AUTH_REVOKED",
    "PERMISSION_DENIED", "RATE_LIMITED", "RESOURCE_NOT_FOUND", "CONFLICT", "UPSTREAM_FAILURE",
    "NETWORK_FAILURE", "UNSUPPORTED", "INTERNAL_ERROR",
    "ACCESS_MODE_INSUFFICIENT", "ACCOUNT_NOT_FOUND", "ATTACHMENT_NOT_FOUND", "AUTH_BOOTSTRAP_NOT_IMPLEMENTED",
    "AUTH_REQUIRED", "CANCELLED", "CONFIG_INVALID", "CREDENTIAL_NOT_FOUND", "DRAFT_NOT_FOUND",
    "FILE_OPERATION_FAILED", "INVALID_DOWNLOAD_KEY", "INVALID_ARGUMENT", "MESSAGE_NOT_FOUND",
    "MUTATION_OUTCOME_UNKNOWN", "PROVIDER_API_ERROR", "PROVIDER_RATE_LIMITED", "RESOURCE_LIMIT",
    "LABEL_NOT_FOUND", "MAIL_INGEST_NOT_SUPPORTED", "MAILBOX_MUTATION_NOT_SUPPORTED",
    "SEND_DISABLED_IN_DRAFT_GATEWAY", "SEND_DISABLED_IN_READER", "SEND_NOT_SUPPORTED", "UNEXPECTED_ERROR"
  ]
  private static let classifications: Set<String> = [
    "validation", "auth", "permission", "rate_limit", "upstream", "network", "internal"
  ]
  private static let providerProblems: Set<String> = [
    "client-forbidden", "not-authorized-for-resource", "unsupported-authentication", "insufficient-scope",
    "usage-capped", "spend-cap-reached", "rate-limit-exceeded", "invalid-request", "resource-not-found", "unknown"
  ]
  private static let providerReasons: Set<String> = [
    "client-not-enrolled", "insufficient-scope", "unsupported-authentication", "usage-capped", "unknown"
  ]

  private static let gmailBodyReasons: Set<String> = [
    "messageEnvelope", "bodyDescriptor", "externalBodyDescriptor", "externalBodyResponse", "treeLimit",
    "filename", "mimeType", "partIdentity", "children", "missingData", "decodedSize", "invalidBase64", "headers",
    "duplicateContentType", "headerValue", "mimeMismatch", "duplicateCharset", "charsetQuotes", "charsetValue"
  ]
  private static let gmailReadReasons: Set<String> = [
    "timeout", "missingResponse", "cancelled", "dns", "connect", "connectionLost", "tls", "offline", "transport"
  ]

  /// Largest failure envelope inspected as-is.
  static let maximumEnvelopeBytes = 65_536
  /// Largest envelope inspected when its size comes from X `error.resourceUsage`
  /// telemetry; the rest of the envelope must still fit `maximumEnvelopeBytes`.
  static let maximumTelemetryEnvelopeBytes = XGatewayUsageCacheExchange.maximumEnvelopeBytes

  static func suffix(stdout: String, stderr: String = "") -> String {
    for text in [stderr, stdout] {
      guard let response = boundedEnvelope(text) else { continue }
      var errors: [JSONObject] = []
      if case let .object(error)? = response["error"] { errors.append(error) }
      if case let .array(values)? = response["errors"] {
        errors += values.prefix(16).compactMap { value in
          guard case let .object(error) = value else { return nil }
          return error
        }
      }
      for error in errors {
        if let suffix = suffix(error: error) { return suffix }
      }
    }
    return ""
  }

  /// X SDK 0.1.24 attaches one `resourceUsage` entry per observed resource to
  /// execution errors, so a spend-cap or rate-limit failure after a large page
  /// can exceed the plain bound. Strip that telemetry before the size check;
  /// other oversized envelopes stay ignored.
  private static func boundedEnvelope(_ text: String) -> JSONObject? {
    let size = text.utf8.count
    if size <= maximumEnvelopeBytes {
      return try? JSONDecoder().decode(JSONObject.self, from: Data(text.utf8))
    }
    guard size <= maximumTelemetryEnvelopeBytes, text.contains("\"resourceUsage\""),
          var response = try? JSONDecoder().decode(JSONObject.self, from: Data(text.utf8)),
          case var .object(error)? = response["error"], error.removeValue(forKey: "resourceUsage") != nil else { return nil }
    response["error"] = .object(error)
    guard let stripped = try? JSONValue.object(response).compactJSONString(),
          stripped.utf8.count <= maximumEnvelopeBytes else { return nil }
    return response
  }

  private static func suffix(error: JSONObject) -> String? {
    guard case let .string(code)? = error["code"], codes.contains(code) else { return nil }
    var fields = ["code=\(code)"]
    if case let .string(classification)? = error["classification"], classifications.contains(classification) {
      fields.append("classification=\(classification)")
    }
    if let status = boundedInteger(error: error, key: "httpStatus", range: 100...599) {
      fields.append("httpStatus=\(status)")
    }
    if case let .string(problem)? = error["providerProblem"], providerProblems.contains(problem) {
      fields.append("providerProblem=\(problem)")
    }
    if case let .string(reason)? = error["providerReason"], providerReasons.contains(reason) {
      fields.append("providerReason=\(reason)")
    }
    if let providerCode = boundedInteger(error: error, key: "providerErrorCode", range: 0...99_999) {
      fields.append("providerErrorCode=\(providerCode)")
    }
    if code == "UPSTREAM_FAILURE",
       boundedInteger(error: error, key: "httpStatus", range: 100...599) == 400,
       let parameter = invalidXRequestParameter(error) {
      fields.append("xInvalidRequestParameter=\(parameter)")
    }
    if case let .bool(retryable)? = error["retryable"] { fields.append("retryable=\(retryable)") }
    for (key, bound) in [("requestAttempts", Int64(11)), ("retryAttempts", Int64(10)), ("backoffMs", Int64(6_000_000))] {
      if case let .integer(value)? = error[key], (0...bound).contains(value) { fields.append("\(key)=\(value)") }
    }
    let retryReasons: Set<String> = ["not-started", "non-retryable", "retry-disabled", "retry-exhausted", "method-not-retryable"]
    if case let .string(reason)? = error["retryStopReason"], retryReasons.contains(reason) {
      fields.append("retryStopReason=\(reason)")
    }
    if code == "PROVIDER_API_ERROR", case let .string(message)? = error["message"] {
      if let counts = gmailDecodedSizeCounts(message) {
        fields += ["gmailBodyReason=decodedSize", "gmailDeclaredByteCount=\(counts.0)", "gmailDecodedByteCount=\(counts.1)"]
      }
      for (field, prefix, reasons) in [
        ("gmailBodyReason", "Invalid message body response", gmailBodyReasons),
        ("gmailReadReason", "Bounded Gmail read failed", gmailReadReasons)
      ] {
        for reason in reasons where message == "\(prefix) [\(field)=\(reason)]" {
          fields.append("\(field)=\(reason)")
        }
      }
    }
    return " (\(fields.joined(separator: ", ")))"
  }

  private static func invalidXRequestParameter(_ error: JSONObject) -> String? {
    // Only finite parameter NAMES cross the reader boundary, never their values,
    // query text, tokens or free-form provider messages.
    guard case let .string(details)? = error["details"], details.utf8.count <= maximumEnvelopeBytes,
          let provider = try? JSONDecoder().decode(JSONObject.self, from: Data(details.utf8)),
          case let .array(errors)? = provider["errors"] else { return nil }
    let allowed: Set<String> = ["query", "since_id", "until_id", "start_time", "end_time",
      "next_token", "pagination_token", "max_results", "expansions", "tweet.fields", "user.fields", "media.fields"]
    var parameters = Set<String>()
    for value in errors.prefix(16) {
      guard case let .object(item) = value, case let .object(values)? = item["parameters"] else { continue }
      parameters.formUnion(values.keys.filter { allowed.contains($0) })
    }
    if parameters.count == 1 { return parameters.first }
    return parameters.isEmpty ? nil : "multiple"
  }

  private static func gmailDecodedSizeCounts(_ message: String) -> (Int, Int)? {
    let prefix = "Invalid message body response [gmailBodyReason=decodedSize declaredByteCount="
    guard message.hasPrefix(prefix), message.hasSuffix("]") else { return nil }
    let values = message.dropFirst(prefix.count).dropLast().components(separatedBy: " decodedByteCount=")
    guard values.count == 2, let declared = gmailByteCount(values[0]), let decoded = gmailByteCount(values[1]) else { return nil }
    return (declared, decoded)
  }

  private static func gmailByteCount(_ text: String) -> Int? {
    guard (1...7).contains(text.utf8.count), text.utf8.allSatisfy({ (48...57).contains($0) }),
          text == "0" || !text.hasPrefix("0"), let value = Int(text), value <= 8_388_608 else { return nil }
    return value
  }

  private static func boundedInteger(error: JSONObject, key: String, range: ClosedRange<Int64>) -> Int64? {
    if case let .integer(value)? = error[key], range.contains(value) { return value }
    if case let .object(extensions)? = error["extensions"],
       case let .integer(value)? = extensions[key], range.contains(value) { return value }
    guard case let .object(details)? = error["details"], case let .string(text)? = details[key],
          (1...5).contains(text.utf8.count), text.utf8.allSatisfy({ (48...57).contains($0) }),
          let value = Int64(text), range.contains(value) else { return nil }
    return value
  }
}
