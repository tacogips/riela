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
    try eventRecordFileURL(id: id, root: root, kind: kind)
  }

  func isSafeEventRecordId(_ value: String) -> Bool {
    isSafeEventRecordIdentifier(value)
  }
}

/// Cron overlap receipts are keyed per (tick, binding) so several bindings on
/// one source never collide (design §7.1). Replays of a binding-scoped receipt
/// reuse the same formula with the replay event id.
func cronOverlapReceiptId(sourceId: String, eventId: String, bindingId: String) -> String {
  let data = Data((sourceId + "\u{0}" + eventId + "\u{0}" + bindingId).utf8)
  return "event-cron-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func isSafeEventRecordIdentifier(_ value: String) -> Bool {
  let scalars = Array(value.unicodeScalars)
  guard (1...128).contains(scalars.count), value != ".", value != "..", !value.contains("..") else {
    return false
  }
  return scalars.allSatisfy { scalar in
    isParityASCIIAlphaNumeric(scalar) || scalar == "." || scalar == "-" || scalar == "_"
  }
}

func eventRecordFileURL(id: String, root: URL, kind: String) throws -> URL {
  guard isSafeEventRecordIdentifier(id) else {
    throw CLIUsageError("invalid \(kind) id '\(id)'")
  }
  let standardizedRoot = root.standardizedFileURL
  let url = standardizedRoot.appendingPathComponent("\(id).json").standardizedFileURL
  guard isURL(url, containedIn: standardizedRoot) else {
    throw CLIUsageError("invalid \(kind) id '\(id)'")
  }
  return url
}

/// The single reader/writer for `<eventRoot>/receipts`. The CLI
/// (`events emit|list|replay`), read-only ingestion and the cron overlap
/// dispatcher all go through it,
/// so every path gets the safe-id and containment checks and the private
/// permissions (directory 0700, files 0600).
struct EventReceiptStore: Sendable {
  let eventRoot: URL

  var root: URL {
    eventRoot.appendingPathComponent("receipts", isDirectory: true)
  }

  func url(for receiptId: String) throws -> URL {
    try eventRecordFileURL(id: receiptId, root: root, kind: "event receipt")
  }

  func save(_ receipt: PersistedEventReceipt) throws {
    let url = try url(for: receipt.receiptId)
    try ensureDirectory()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(receipt).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  func load(_ receiptId: String) throws -> PersistedEventReceipt? {
    let url = try url(for: receiptId)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Self.decoder().decode(PersistedEventReceipt.self, from: Data(contentsOf: url))
  }

  /// Newest first (`updatedAt` descending, then `receiptId`), so `--limit`
  /// returns the most recent outcomes even though cron ids are hashes.
  func list() throws -> [PersistedEventReceipt] {
    try receiptFileURLs()
      .map { try Self.decoder().decode(PersistedEventReceipt.self, from: Data(contentsOf: $0)) }
      .sorted { lhs, rhs in
        lhs.updatedAt != rhs.updatedAt ? lhs.updatedAt > rhs.updatedAt : lhs.receiptId < rhs.receiptId
      }
  }

  /// Like `list`, unsorted, but skips files that cannot be read or decoded,
  /// for best-effort maintenance passes that must not stop at one bad file.
  func listSkippingUnreadable() -> [PersistedEventReceipt] {
    let decoder = Self.decoder()
    return ((try? receiptFileURLs()) ?? []).compactMap { url in
      (try? Data(contentsOf: url)).flatMap { try? decoder.decode(PersistedEventReceipt.self, from: $0) }
    }
  }

  private func receiptFileURLs() throws -> [URL] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
  }

  private func ensureDirectory() throws {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue {
      return
    }
    try FileManager.default.createDirectory(at: eventRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
