import Foundation

/// JSON Lines are separated by ASCII LF; Unicode separators inside JSON strings
/// remain payload. CRLF works because the trailing CR is JSON whitespace.
public enum JSONLRecordFraming {
  public static func records(in text: String) -> [String] {
    text.components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}
