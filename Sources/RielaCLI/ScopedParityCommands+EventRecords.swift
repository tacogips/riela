import Crypto
import Foundation

extension ScopedParityCommandRunner {
  func safeReceiptId(sourceId: String, eventId: String) -> String {
    let raw = "\(sourceId)\u{0}\(eventId)"
    let encoded = Data(raw.utf8)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    let legacyId = "event-\(encoded)"
    if legacyId.count <= 128 { return legacyId }
    let digest = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    return "event-sha256-" + digest
  }

  func eventRecordURL(id: String, root: URL, kind: String) throws -> URL {
    guard isSafeEventRecordId(id) else {
      throw CLIUsageError("invalid \(kind) id '\(id)'")
    }
    let standardizedRoot = root.standardizedFileURL
    let url = standardizedRoot.appendingPathComponent("\(id).json").standardizedFileURL
    guard isURL(url, containedIn: standardizedRoot) else {
      throw CLIUsageError("invalid \(kind) id '\(id)'")
    }
    return url
  }

  func isSafeEventRecordId(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    guard (1...128).contains(scalars.count), value != ".", value != "..", !value.contains("..") else {
      return false
    }
    return scalars.allSatisfy { scalar in
      isParityASCIIAlphaNumeric(scalar) || scalar == "." || scalar == "-" || scalar == "_"
    }
  }

}
