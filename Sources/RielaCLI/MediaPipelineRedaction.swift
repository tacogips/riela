import Foundation

/// Redacts credentials from media-stage diagnostics before they reach node errors.
enum MediaPipelineRedaction {
  private static let secretNameMarkers = ["KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "AUTH", "COOKIE"]
  private static let rules: [(NSRegularExpression, String)] = [
    // URL userinfo, query and fragment; scheme, host and path stay readable.
    (#"(?i)\b([a-z][a-z0-9+.-]*://)(?:[^\s/?#@]*@)?([^\s?#]*)(?:\?[^\s#]*)?(?:#\S*)?"#, "$1$2"),
    (#"(?i)\b(authorization|proxy-authorization|cookie|set-cookie)(\s*[:=]\s*)[^\r\n]*"#, "$1$2[REDACTED]"),
    (#"(?i)\b(basic|bearer)(\s+)[A-Za-z0-9._~+/=-]+"#, "$1$2[REDACTED]"),
    (#"sk-[A-Za-z0-9_-]{8,}"#, "[REDACTED]"),
    (#"(?i)\b([A-Z0-9_]*(?:API_KEY|TOKEN|SECRET|PASSWORD)\s*[=:]\s*)[^\s,;]+"#, "$1[REDACTED]"),
  ].compactMap { pattern, template in
    (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
  }

  static func redact(_ text: String, environment: [String: String]) -> String {
    var message = text
    for (name, secret) in environment where secret.count >= 4 && isSecretName(name) {
      message = message.replacingOccurrences(of: secret, with: "[REDACTED]")
    }
    for (expression, template) in rules {
      message = expression.stringByReplacingMatches(
        in: message, range: NSRange(message.startIndex..., in: message), withTemplate: template)
    }
    return message
  }

  /// Redacted, single-line tail suitable for a node error message.
  static func diagnostic(_ text: String, environment: [String: String], limit: Int = 500) -> String {
    let redacted = redact(text, environment: environment)
    let singleLine = redacted.unicodeScalars
      .map { CharacterSet.newlines.contains($0) ? " " : String($0) }.joined()
    return String(singleLine.suffix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func isSecretName(_ name: String) -> Bool {
    let upper = name.uppercased()
    return secretNameMarkers.contains { upper.contains($0) }
  }
}
