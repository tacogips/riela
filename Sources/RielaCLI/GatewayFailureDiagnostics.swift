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
    "usage-capped", "rate-limit-exceeded", "invalid-request", "resource-not-found", "unknown"
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

  static func suffix(stdout: String, stderr: String = "") -> String {
    for text in [stderr, stdout] where text.utf8.count <= 65_536 {
      guard let response = try? JSONDecoder().decode(JSONObject.self, from: Data(text.utf8)) else { continue }
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
