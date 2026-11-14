import Foundation
import RielaCore

/// A distinct pre-request refusal: no credentials, provider or model has run.
struct EmptyWorkerInput: Error, Sendable {}

enum WorkerJSONLInput {
  static let nodeEmptyMessage = "isolated node worker received no request bytes"
  static let privateEmptyMessage = "private workflow worker received no request bytes"

  static func decode<T: Decodable>(_ type: T.Type, from bytes: Data, framingMessage: String) throws -> T {
    if bytes.allSatisfy({ [9, 10, 13, 32].contains($0) }) { throw EmptyWorkerInput() }
    // JSONL uses ASCII LF. Unicode line/paragraph separators are valid inside
    // JSON strings and must not be mistaken for additional protocol records.
    guard String(data: bytes, encoding: .utf8) != nil, bytes.split(separator: 10).count == 1 else {
      throw AdapterExecutionError(.invalidInput, framingMessage)
    }
    return try JSONDecoder().decode(type, from: bytes)
  }
}
