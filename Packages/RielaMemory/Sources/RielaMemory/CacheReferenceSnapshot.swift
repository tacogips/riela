import Foundation

/// References can be nested in queue/checkpoint metadata. No application schema
/// or source body is needed. The reserved reference shape is any object that has
/// both a `key` and a `revision` member: its revision must be a SHA256 hex
/// digest, otherwise the snapshot is rejected. An object whose string `scope`
/// member names a different scope (for example a put receipt from another
/// scope) is skipped, so receipts can be passed through verbatim.
enum CacheReferenceSnapshot {
  static func collect(_ value: MemoryJSONValue, scope: String) throws -> [String: String] {
    var result: [String: String] = [:]
    var remaining = 1_000_000
    func visit(_ value: MemoryJSONValue, depth: Int) throws {
      remaining -= 1
      guard depth <= 64, remaining >= 0 else { throw RielaCacheError.invalid("reference snapshot exceeds bound") }
      switch value {
      case let .object(object):
        if let keyValue = object["key"], let revisionValue = object["revision"] {
          if case let .string(referenceScope) = object["scope"], referenceScope != scope { return }
          guard case let .string(key) = keyValue, case let .string(revision) = revisionValue,
            !key.isEmpty, key.utf8.count <= 1024, !key.contains("\0"),
            key == key.trimmingCharacters(in: .whitespacesAndNewlines),
            revision.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw RielaCacheError.invalid("invalid retained cache reference")
          }
          if let previous = result[key], previous != revision { throw RielaCacheError.revisionConflict(key) }
          result[key] = revision
          guard result.count <= 10_000 else { throw RielaCacheError.invalid("too many retained references") }
          return
        }
        for child in object.values { try visit(child, depth: depth + 1) }
      case let .array(values):
        for child in values { try visit(child, depth: depth + 1) }
      default: break
      }
    }
    guard case .object = value else {
      if case .array = value { try visit(value, depth: 0); return result }
      throw RielaCacheError.invalid("reference snapshot must be an object or array")
    }
    try visit(value, depth: 0)
    return result
  }
}
