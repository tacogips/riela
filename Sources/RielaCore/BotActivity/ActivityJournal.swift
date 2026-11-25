import Foundation
import RielaSQLite

public struct ActivityLimits: Sendable {
  public static let `default` = ActivityLimits()

  public let maxEventsPerSession: Int
  public let maxPayloadBytes: Int
  public let textFlushBytes: Int
  public let textFlushIntervalMs: Int
  public let requestPollIntervalMs: Int

  public init(
    maxEventsPerSession: Int = 2_000, maxPayloadBytes: Int = 8_192,
    textFlushBytes: Int = 4_096, textFlushIntervalMs: Int = 1_000, requestPollIntervalMs: Int = 500
  ) {
    self.maxEventsPerSession = max(1, maxEventsPerSession)
    self.maxPayloadBytes = max(32, maxPayloadBytes)
    self.textFlushBytes = max(1, textFlushBytes)
    self.textFlushIntervalMs = max(1, textFlushIntervalMs)
    self.requestPollIntervalMs = max(1, requestPollIntervalMs)
  }

  public static func sleep(nanoseconds: UInt64) async {
    try? await Task.sleep(nanoseconds: nanoseconds)
  }
}

struct ActivityJournal {
  private struct Write {
    let executionId: String
    let at: Date
    let event: ActivityEventDraft
  }

  let sessionId: String
  var state: ActivityState
  var lastSequence: Int
  var firstRetainedSequence: Int
  private var maxEventsPerSession: Int
  private var maxPayloadBytes: Int
  private var drafts: [Write] = []

  init(sessionId: String, db: SQLiteDatabase) throws {
    self.sessionId = sessionId
    let row = try db.query(
      """
      SELECT json(state_json) AS state_json, last_seq, first_retained_seq,
             json_extract(state_json, '$._journalMaxEvents') AS max_events,
             json_extract(state_json, '$._journalMaxPayloadBytes') AS max_payload_bytes
      FROM activity_state WHERE session_id = ?
      """, bindings: [.text(sessionId)]
    ).first
    state = try row.map { try Self.decode(ActivityState.self, column: "state_json", row: $0) } ?? ActivityState()
    lastSequence = row?["last_seq"].flatMap(Int.init) ?? 0
    firstRetainedSequence = row?["first_retained_seq"].flatMap(Int.init) ?? 1
    maxEventsPerSession = row?["max_events"].flatMap(Int.init) ?? ActivityLimits.default.maxEventsPerSession
    maxPayloadBytes = row?["max_payload_bytes"].flatMap(Int.init) ?? ActivityLimits.default.maxPayloadBytes
  }

  mutating func append(_ events: [ActivityEventDraft], executionId: String, at: Date) {
    if !events.isEmpty {
      state.lastEventAt = at
      drafts.append(contentsOf: events.map { Write(executionId: executionId, at: at, event: $0) })
    }
  }

  mutating func finishMessageIfNeeded(executionId: String, at: Date, db: SQLiteDatabase) throws {
    let latest: JSONObject?
    if let draft = drafts.last(where: { $0.executionId == executionId && $0.event.kind == .message }) {
      latest = draft.event.payload
    } else {
      let row = try db.query(
        """
        SELECT json(payload_json) AS payload_json FROM activity_events
        WHERE session_id = ? AND execution_id = ? AND kind = 'message' ORDER BY seq DESC LIMIT 1
        """, bindings: [.text(sessionId), .text(executionId)]
      ).first
      latest = try row.map { try Self.decode(JSONObject.self, column: "payload_json", row: $0) }
    }
    guard let latest, latest["final"] != .bool(true) else { return }
    var marker: JSONObject = ["text": .string(""), "final": .bool(true)]
    marker["messageId"] = latest["messageId"]
    append([.init(kind: .message, payload: marker)], executionId: executionId, at: at)
  }

  mutating func save(in db: SQLiteDatabase, at: Date, limits: ActivityLimits? = nil) throws {
    if let limits {
      maxEventsPerSession = limits.maxEventsPerSession
      maxPayloadBytes = limits.maxPayloadBytes
    }
    for draft in drafts {
      lastSequence += 1
      try db.execute(
        """
        INSERT INTO activity_events (session_id, seq, execution_id, at, kind, payload_json)
        VALUES (?, ?, ?, ?, ?, jsonb(?))
        """, bindings: [
          .text(sessionId), .int(Int64(lastSequence)), .text(draft.executionId),
          .text(RoutineStore.timestamp(draft.at)), .text(draft.event.kind.rawValue),
          .text(try Self.boundedJSON(draft.event.payload, limit: maxPayloadBytes))
        ]
      )
    }
    let cutoff = lastSequence - maxEventsPerSession
    if cutoff >= firstRetainedSequence {
      try db.execute(
        "DELETE FROM activity_events WHERE session_id = ? AND seq <= ?",
        bindings: [.text(sessionId), .int(Int64(cutoff))]
      )
      firstRetainedSequence = cutoff + 1
    }
    try db.execute(
      """
      INSERT INTO activity_state (session_id, state_json, last_seq, first_retained_seq, source, updated_at)
      VALUES (?, jsonb_set(jsonb(?), '$._journalMaxEvents', ?, '$._journalMaxPayloadBytes', ?), ?, ?, ?, ?)
      ON CONFLICT(session_id) DO UPDATE SET state_json = excluded.state_json, last_seq = excluded.last_seq,
        first_retained_seq = excluded.first_retained_seq, source = excluded.source, updated_at = excluded.updated_at
      """, bindings: [
        .text(sessionId), .text(try Self.encode(state)), .int(Int64(maxEventsPerSession)), .int(Int64(maxPayloadBytes)),
        .int(Int64(lastSequence)), .int(Int64(firstRetainedSequence)), .text(state.source), .text(RoutineStore.timestamp(at))
      ]
    )
  }

  static func encode(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let encoded = String(bytes: try encoder.encode(value), encoding: .utf8) else {
      throw BotStoreError(code: "activity_record_invalid", message: "Activity JSON could not be encoded as UTF-8")
    }
    return encoded
  }

  static func decode<Value: Decodable>(_ type: Value.Type, column: String, row: SQLiteRow) throws -> Value {
    guard let value = row[column] else {
      throw BotStoreError(code: "activity_record_invalid", message: "Missing activity column \(column)")
    }
    return try JSONDecoder().decode(type, from: Data(value.utf8))
  }

  static func date(column: String, row: SQLiteRow) throws -> Date {
    let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    guard let value = row[column], let date = try? format.parse(value) else {
      throw BotStoreError(code: "activity_record_invalid", message: "Invalid activity date in \(column)")
    }
    return date
  }

  private static func boundedJSON(_ payload: JSONObject, limit: Int) throws -> String {
    let encoded = try encode(payload)
    guard encoded.utf8.count > limit else { return encoded }
    var bounded: JSONObject = ["truncated": .bool(true)]
    // Keep identifiers and other compact fields even when an array or text is oversized.
    let keys = payload.keys.sorted { ($0 == "text" ? 1 : 0, $0) < ($1 == "text" ? 1 : 0, $1) }
    for key in keys where key != "truncated" {
      bounded[key] = payload[key]
      if try encode(bounded).utf8.count > limit {
        bounded[key] = nil
        if case let .string(text) = payload[key] {
          bounded[key] = try fittingText(text, key: key, payload: bounded, limit: limit).map(JSONValue.string)
        }
      }
    }
    return try encode(bounded)
  }

  private static func fittingText(_ text: String, key: String, payload: JSONObject, limit: Int) throws -> String? {
    let scalars = Array(text.unicodeScalars.prefix(limit))
    var low = 0
    var high = scalars.count
    var result: String?
    var candidate = payload
    while low <= high {
      let middle = low + (high - low) / 2
      let prefix = String(String.UnicodeScalarView(scalars.prefix(middle)))
      candidate[key] = .string(prefix)
      if try encode(candidate).utf8.count <= limit {
        result = prefix
        low = middle + 1
      } else {
        high = middle - 1
      }
    }
    return result
  }
}
