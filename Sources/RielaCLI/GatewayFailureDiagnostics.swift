import Foundation
import RielaCore

/// Retains finite machine diagnostics only. Provider text and arbitrary extensions never leave the reader boundary.
enum GatewayFailureDiagnostics {
  private static let codes: Set<String> = [
    "VALIDATION_ERROR", "AUTH_MISSING", "AUTH_INVALID", "AUTH_EXPIRED", "AUTH_REVOKED",
    "PERMISSION_DENIED", "RATE_LIMITED", "RESOURCE_NOT_FOUND", "CONFLICT", "UPSTREAM_FAILURE",
    "NETWORK_FAILURE", "UNSUPPORTED", "INTERNAL_ERROR"
  ]
  private static let classifications: Set<String> = [
    "validation", "auth", "permission", "rate_limit", "upstream", "network", "internal"
  ]

  static func suffix(stdout: String, stderr: String = "") -> String {
    for text in [stderr, stdout] where text.utf8.count <= 65_536 {
      guard let response = try? JSONDecoder().decode(JSONObject.self, from: Data(text.utf8)),
            case let .object(error)? = response["error"],
            case let .string(code)? = error["code"], codes.contains(code) else { continue }
      var fields = ["code=\(code)"]
      if case let .string(classification)? = error["classification"], classifications.contains(classification) {
        fields.append("classification=\(classification)")
      }
      if case let .integer(status)? = error["httpStatus"], (100...599).contains(status) {
        fields.append("httpStatus=\(status)")
      }
      return " (\(fields.joined(separator: ", ")))"
    }
    return ""
  }
}
