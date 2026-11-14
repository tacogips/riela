import Crypto
import Foundation

extension RielaMemoryStore {
  /// Attachments are retained once at their stored path, independently of the
  /// record's reverse deltas. Hashes bind historical references to exact bytes.
  func verifyEvolutionAttachments(_ files: [MemoryFileReference], db: OpaquePointer?, recordMissing: Bool) throws {
    for file in files {
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw MemoryEvolutionError.missingAttachment(file.path)
      }
      let bytes = try Data(contentsOf: URL(fileURLWithPath: file.path))
      let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      let rows = try queryRows(db, sql: "SELECT content_sha256 FROM memory_evolution_attachments WHERE path = ?",
        bindings: [.text(file.path)])
      if let expected = rows.first?.columns["content_sha256"] {
        guard expected == digest else { throw EvolutionReverseDelta.ValidationError.sourceMismatch }
      } else if recordMissing {
        try execute(db, "INSERT INTO memory_evolution_attachments(path, content_sha256) VALUES (?, ?)",
          bindings: [.text(file.path), .text(digest)])
      } else {
        throw RielaMemoryError.sqliteFailed("historical attachment has no integrity record")
      }
    }
  }
}
