import Foundation
import RielaCore
import RielaSQLite

public extension WorkStore {
  func saveHostSnapshot(_ snapshot: HostCapabilitySnapshot) throws {
    let db = try openWritable()
    try db.transaction { db in
      var latest = snapshot
      let rows = try db.query(
        "SELECT json(record) AS record FROM work_hosts WHERE host_id = ?",
        bindings: [.text(snapshot.hostId)]
      )
      if let record = rows.first?["record"] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let existing = try decoder.decode(HostCapabilitySnapshot.self, from: Data(record.utf8))
        if let existingObservation = existing.capabilitiesObservedAt,
          let incomingObservation = snapshot.capabilitiesObservedAt {
          if existingObservation >= incomingObservation {
            latest = existing
          }
          latest.refreshedAt = snapshot.refreshedAt
        }
      }
      try db.execute(
        """
        INSERT INTO work_hosts (host_id, record, updated_at)
        VALUES (?, jsonb(?), ?)
        ON CONFLICT(host_id) DO UPDATE SET
          record = excluded.record,
          updated_at = excluded.updated_at
        """,
        bindings: [
          .text(snapshot.hostId),
          .text(try encode(latest)),
          .text(Self.timestamp(latest.refreshedAt))
        ]
      )
    }
  }

  func loadHostSnapshots() throws -> [HostCapabilitySnapshot] {
    guard FileManager.default.fileExists(atPath: databasePath) else { return [] }
    let db = try SQLiteDatabase.open(
      path: databasePath,
      mode: .strictReadOnlyWithImmutableFallback,
      options: .readOnlyDefault
    )
    guard try db.tableExists("work_hosts") else { return [] }
    let rows = try db.query("SELECT json(record) AS record FROM work_hosts ORDER BY host_id ASC")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try rows.map { row in
      guard let json = row["record"] else { throw WorkStoreError("work host row is missing its record") }
      return try decoder.decode(HostCapabilitySnapshot.self, from: Data(json.utf8))
    }
  }
}
