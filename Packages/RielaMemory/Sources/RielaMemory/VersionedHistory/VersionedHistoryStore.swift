import Foundation

public struct VersionedHistoryStore {
  private struct EncodedValue {
    var encoding: String
    var codec: String
    var blob: Data?
  }

  private struct Row: Sendable {
    var version: Int64
    var createdAt: String
    var hash: String
    var byteCount: Int64
    var encoding: String
    var anchor: Int64?
    var codec: String
    var detached: Bool
    var blob: Data?
    var storedBytes: Int64
  }

  private let prefix: String
  private let headStorage: VersionedHistoryHeadStorage
  private let sql: any VersionedHistorySQL
  private let now: @Sendable () -> Date
  private let withGuardedDelete: (@escaping () throws -> Void) throws -> Void

  public init(tablePrefix: String, headStorage: VersionedHistoryHeadStorage, sql: any VersionedHistorySQL,
              now: @escaping @Sendable () -> Date = Date.init,
              withGuardedDelete: @escaping (@escaping () throws -> Void) throws -> Void = { try $0() }) {
    precondition(tablePrefix.range(of: "^[a-z]+$", options: .regularExpression) != nil, "tablePrefix must match ^[a-z]+$")
    self.prefix = tablePrefix
    self.headStorage = headStorage
    self.sql = sql
    self.now = now
    self.withGuardedDelete = withGuardedDelete
  }

  private var heads: String { "\(prefix)_history_heads" }
  private var versionsTable: String { "\(prefix)_history_versions" }

  public func ensureSchema() throws {
    try sql.execute("""
      CREATE TABLE IF NOT EXISTS \(heads)(key TEXT PRIMARY KEY, revision INTEGER NOT NULL, head_version INTEGER NOT NULL,
        retained_generations INTEGER, updated_at TEXT NOT NULL)
      """, [])
    try sql.execute("""
      CREATE TABLE IF NOT EXISTS \(versionsTable)(key TEXT NOT NULL, version INTEGER NOT NULL, created_at TEXT NOT NULL,
        content_sha256 TEXT NOT NULL, byte_count INTEGER NOT NULL,
        encoding TEXT NOT NULL CHECK (encoding IN ('head','full','delta','external')),
        anchor_version INTEGER, codec TEXT NOT NULL CHECK (codec IN ('none','zlib')),
        detached INTEGER NOT NULL DEFAULT 0, blob BLOB, PRIMARY KEY (key, version))
      """, [])
    try sql.execute("CREATE INDEX IF NOT EXISTS \(prefix)_history_versions_order ON \(versionsTable)(key, version)", [])
  }

  public func head(key: String) throws -> VersionedHistoryHead? {
    guard let row = try sql.query("SELECT key, revision, head_version, retained_generations FROM \(heads) WHERE key = ?", [.text(key)]).first else { return nil }
    return VersionedHistoryHead(key: key, revision: row.int("revision"), headVersion: row.int("head_version"), retainedGenerations: row.optionalInt("retained_generations").map(Int.init))
  }

  public func write(key: String, value: Data, currentHeadValue: Data?, expectedRevision: Int64?, force: Bool,
                    retainedGenerations: Int?, defaultRetainedGenerations: Int, pins: Set<Int64>) throws -> VersionedHistoryWriteResult {
    guard defaultRetainedGenerations >= 0 else { throw VersionedHistoryError.invalidRetention(defaultRetainedGenerations) }
    if let retainedGenerations, retainedGenerations < 0 { throw VersionedHistoryError.invalidRetention(retainedGenerations) }
    let oldHead = try head(key: key)
    if let expectedRevision, expectedRevision != (oldHead?.revision ?? 0) {
      throw VersionedHistoryError.staleRevision(expected: expectedRevision, actual: oldHead?.revision ?? 0)
    }
    if let oldHead {
      let oldValue = try headValue(key: key, head: oldHead, supplied: currentHeadValue)
      if !force, VersionedHistoryCodec.sha256(oldValue) == VersionedHistoryCodec.sha256(value) {
        return VersionedHistoryWriteResult(outcome: .unchanged, version: oldHead.headVersion, revision: oldHead.revision, droppedVersions: [], freedBytes: 0)
      }
    } else if headStorage == .external, currentHeadValue != nil {
      throw VersionedHistoryError.historyCorrupt("external head supplied for an empty history")
    }

    let nextRevision = (oldHead?.revision ?? 0) + 1
    var freed: Int64 = 0
    var dropped: [Int64] = []
    if let oldHead {
      let oldValue = try headValue(key: key, head: oldHead, supplied: currentHeadValue)
      let all = try rows(key: key)
      for row in all where row.version > oldHead.headVersion {
        if pins.contains(row.version) {
          let payload = try reconstruct(key: key, target: row.version, head: oldHead, headValue: oldValue, rows: all)
          try store(row: row, key: key, encoding: "full", anchor: nil, value: payload, detached: true)
        } else {
          freed += row.storedBytes
          dropped.append(row.version)
          try guardedDelete(key: key, version: row.version)
        }
      }
      try storeHeadAsVersion(key: key, version: oldHead.headVersion, value: oldValue, anchor: value, anchorVersion: nextRevision)
    }
    try insertHead(key: key, version: nextRevision, revision: nextRevision, value: value, retention: retainedGenerations, createdAt: timestamp())
    let effective = retainedGenerations ?? oldHead?.retainedGenerations ?? defaultRetainedGenerations
    let result = try applyRetentionInternal(key: key, headVersion: nextRevision, headValue: value, retainedGenerations: effective, pins: pins)
    dropped += result.dropped
    freed += result.freedBytes
    return VersionedHistoryWriteResult(outcome: .written, version: nextRevision, revision: nextRevision, droppedVersions: Array(Set(dropped)).sorted(), freedBytes: freed)
  }

  public func undo(key: String, currentHeadValue: Data?, expectedRevision: Int64?) throws -> VersionedHistoryHeadMove {
    try moveHead(key: key, currentHeadValue: currentHeadValue, expectedRevision: expectedRevision, redo: false)
  }

  public func redo(key: String, currentHeadValue: Data?, expectedRevision: Int64?) throws -> VersionedHistoryHeadMove {
    try moveHead(key: key, currentHeadValue: currentHeadValue, expectedRevision: expectedRevision, redo: true)
  }

  public func value(key: String, version: Int64, currentHeadValue: Data?) throws -> Data {
    guard let head = try head(key: key) else { throw VersionedHistoryError.versionNotRetained(version: version, retained: [], retainedGenerations: nil) }
    let all = try rows(key: key)
    guard all.contains(where: { $0.version == version }) else {
      throw VersionedHistoryError.versionNotRetained(version: version, retained: all.map(\.version).sorted(by: >), retainedGenerations: head.retainedGenerations)
    }
    return try reconstruct(key: key, target: version, head: head, headValue: headValue(key: key, head: head, supplied: currentHeadValue), rows: all)
  }

  public func versions(key: String, limit: Int, beforeVersion: Int64?) throws -> [VersionedHistoryVersionInfo] {
    guard limit > 0, let head = try head(key: key) else { return [] }
    return try rows(key: key).filter { item in beforeVersion.map { item.version < $0 } ?? true }
      .sorted { $0.version > $1.version }.prefix(limit).map { row in
        VersionedHistoryVersionInfo(version: row.version, createdAt: row.createdAt, isHead: row.version == head.headVersion,
          detached: row.detached, encoding: row.encoding, codec: row.codec, storedBytes: row.storedBytes,
          byteCount: row.byteCount, sha256: row.hash)
      }
  }

  public func applyRetention(key: String, currentHeadValue: Data?, retainedGenerations: Int, pins: Set<Int64>) throws -> (dropped: [Int64], freedBytes: Int64) {
    guard retainedGenerations >= 0 else { throw VersionedHistoryError.invalidRetention(retainedGenerations) }
    guard let head = try head(key: key) else { return ([], 0) }
    let bytes = try headValue(key: key, head: head, supplied: currentHeadValue)
    let result = try applyRetentionInternal(key: key, headVersion: head.headVersion, headValue: bytes, retainedGenerations: retainedGenerations, pins: pins)
    try sql.execute("UPDATE \(heads) SET retained_generations = ?, updated_at = ? WHERE key = ?", [.int(Int64(retainedGenerations)), .text(timestamp()), .text(key)])
    return result
  }

  /// Retains exactly the requested generations, plus the current head. This
  /// supports explicit history purge while preserving the engine's guarded
  /// deletion and survivor re-encoding behavior.
  public func retainVersions(key: String, currentHeadValue: Data?, versions: Set<Int64>) throws -> (dropped: [Int64], freedBytes: Int64) {
    guard let head = try head(key: key) else { return ([], 0) }
    let bytes = try headValue(key: key, head: head, supplied: currentHeadValue)
    let result = try applyRetentionInternal(key: key, headVersion: head.headVersion, headValue: bytes,
      retainedGenerations: nil, pins: versions.union([head.headVersion]), preserveRedoBranch: false)
    return result
  }

  public func importChain(key: String, revision: Int64, headVersion: Int64, headValue: Data,
    // swiftlint:disable:next large_tuple
                          previous: [(version: Int64, createdAt: String, value: Data)]) throws {
    try deleteAll(key: key)
    try insertHead(key: key, version: headVersion, revision: revision, value: headValue, retention: nil, createdAt: timestamp())
    let ordered = previous.sorted { $0.version < $1.version }
    for item in ordered {
      let towardHead = ordered.first(where: { $0.version > item.version })
      let anchorValue = towardHead?.value ?? headValue
      let anchorVersion = towardHead?.version ?? headVersion
      let encodedValue = try encoded(item.value, against: anchorValue, detached: false)
      try sql.execute("INSERT INTO \(versionsTable)(key,version,created_at,content_sha256,byte_count,encoding,anchor_version,codec,detached,blob) VALUES(?,?,?,?,?,?,?,?,0,?)",
        [.text(key), .int(item.version), .text(item.createdAt), .text(VersionedHistoryCodec.sha256(item.value)), .int(Int64(item.value.count)), .text(encodedValue.encoding),
         encodedValue.encoding == "delta" ? .int(anchorVersion) : .null, .text(encodedValue.codec), encodedValue.blob.map(VersionedHistorySQLValue.blob) ?? .null])
    }
  }

  public func deleteAll(key: String) throws {
    for row in try rows(key: key) { try guardedDelete(key: key, version: row.version) }
    try sql.execute("DELETE FROM \(heads) WHERE key = ?", [.text(key)])
  }

  private func moveHead(key: String, currentHeadValue: Data?, expectedRevision: Int64?, redo: Bool) throws -> VersionedHistoryHeadMove {
    guard let current = try head(key: key) else { throw VersionedHistoryError.historyCorrupt("missing history head") }
    if let expectedRevision, expectedRevision != current.revision { throw VersionedHistoryError.staleRevision(expected: expectedRevision, actual: current.revision) }
    let currentValue = try headValue(key: key, head: current, supplied: currentHeadValue)
    let all = try rows(key: key)
    let candidates = all.filter { !$0.detached && (redo ? $0.version > current.headVersion : $0.version < current.headVersion) }
    guard let target = redo ? candidates.min(by: { $0.version < $1.version }) : candidates.max(by: { $0.version < $1.version }) else {
      if redo { throw VersionedHistoryError.nothingToRedo }
      throw VersionedHistoryError.nothingToUndo(oldestRetained: all.map(\.version).min() ?? current.headVersion)
    }
    let targetValue = try reconstruct(key: key, target: target.version, head: current, headValue: currentValue, rows: all)
    try storeHeadAsVersion(key: key, version: current.headVersion, value: currentValue, anchor: targetValue, anchorVersion: target.version)
    try setHeadRow(key: key, version: target.version, value: targetValue)
    let newRevision = current.revision + 1
    try sql.execute("UPDATE \(heads) SET revision = ?, head_version = ?, updated_at = ? WHERE key = ?",
                    [.int(newRevision), .int(target.version), .text(timestamp()), .text(key)])
    return VersionedHistoryHeadMove(fromVersion: current.headVersion, toVersion: target.version, revision: newRevision, value: targetValue)
  }

  private func applyRetentionInternal(
    key: String,
    headVersion: Int64,
    headValue: Data,
    retainedGenerations: Int?,
    pins: Set<Int64>,
    preserveRedoBranch: Bool = true
  ) throws -> (dropped: [Int64], freedBytes: Int64) {
    if let retainedGenerations, retainedGenerations < 0 { throw VersionedHistoryError.invalidRetention(retainedGenerations) }
    if retainedGenerations == 0 { return ([], 0) }
    let all = try rows(key: key)
    let nonDetached = all.filter { !$0.detached }
    let redoBranch = preserveRedoBranch ? nonDetached.filter { $0.version > headVersion }.map(\.version) : []
    let priorVersions = nonDetached.filter { $0.version < headVersion }
      .sorted { $0.version > $1.version }
      .prefix(max((retainedGenerations ?? 1) - 1, 0))
      .map(\.version)
    let keep = Set([headVersion]).union(redoBranch).union(priorVersions).union(pins)
    let removing = all.filter { !keep.contains($0.version) }
    var values: [Int64: Data] = [:]
    let currentHead = try head(key: key) ?? VersionedHistoryHead(key: key, revision: headVersion, headVersion: headVersion, retainedGenerations: nil)
    for survivor in all where keep.contains(survivor.version) {
      if survivor.version == headVersion { values[survivor.version] = headValue } else {
        values[survivor.version] = try reconstruct(key: key, target: survivor.version, head: currentHead, headValue: headValue, rows: all)
      }
    }
    var freed: Int64 = 0
    for row in removing { freed += row.storedBytes; try guardedDelete(key: key, version: row.version) }
    let ordered = keep.sorted()
    for version in ordered where version != headVersion {
      guard let content = values[version], let source = all.first(where: { $0.version == version }) else { continue }
      if source.detached {
        try store(row: source, key: key, encoding: "full", anchor: nil, value: content, detached: true)
        continue
      }
      let toward = version < headVersion ? ordered.filter { $0 > version && $0 <= headVersion }.min() : ordered.filter { $0 < version && $0 >= headVersion }.max()
      let anchorBytes = toward.flatMap { values[$0] }
      try store(row: source, key: key, encoding: "delta", anchor: anchorBytes, value: content, detached: false, anchorVersion: toward)
    }
    return (removing.map(\.version), freed)
  }

  private func reconstruct(key: String, target: Int64, head: VersionedHistoryHead, headValue: Data, rows: [Row]) throws -> Data {
    guard let targetRow = rows.first(where: { $0.version == target }) else {
      throw VersionedHistoryError.versionNotRetained(version: target, retained: rows.map(\.version).sorted(by: >), retainedGenerations: head.retainedGenerations)
    }
    if target == head.headVersion { try verify(targetRow, data: headValue); return headValue }
    var visited = Set<Int64>()
    func visit(_ row: Row) throws -> Data {
      guard visited.insert(row.version).inserted else { throw VersionedHistoryError.historyCorrupt("anchor cycle at \(row.version)") }
      if row.encoding == "full" {
        guard let blob = row.blob else { throw VersionedHistoryError.historyCorrupt("full row missing blob") }
        let value = try VersionedHistoryCodec.decompressed(blob, codec: row.codec, byteCount: row.byteCount)
        try verify(row, data: value)
        return value
      }
      guard row.encoding == "delta", let anchor = row.anchor else { throw VersionedHistoryError.historyCorrupt("missing anchor for version \(row.version)") }
      let base: Data
      if anchor == head.headVersion {
        base = headValue
      } else {
        guard let anchorRow = rows.first(where: { $0.version == anchor }) else {
          throw VersionedHistoryError.historyCorrupt("missing anchor version \(anchor)")
        }
        base = try visit(anchorRow)
      }
      guard let blob = row.blob else { throw VersionedHistoryError.historyCorrupt("delta row missing blob") }
      let splice = try VersionedHistoryCodec.decompressed(blob, codec: row.codec, byteCount: row.byteCount + 16, exact: false)
      let decoded = try VersionedHistoryCodec.apply(splice, to: base)
      try verify(row, data: decoded)
      return decoded
    }
    return try visit(targetRow)
  }

  private func verify(_ row: Row, data: Data) throws {
    guard Int64(data.count) == row.byteCount, VersionedHistoryCodec.sha256(data) == row.hash else {
      throw VersionedHistoryError.historyCorrupt("content verification failed for version \(row.version)")
    }
  }

  private func headValue(key: String, head: VersionedHistoryHead, supplied: Data?) throws -> Data {
    if headStorage == .external {
      guard let supplied else { throw VersionedHistoryError.historyCorrupt("external head value required for \(key)") }
      guard let row = try row(key: key, version: head.headVersion) else { throw VersionedHistoryError.historyCorrupt("external head row missing for \(key)") }
      try verify(row, data: supplied)
      return supplied
    }
    guard let row = try row(key: key, version: head.headVersion), let blob = row.blob else { throw VersionedHistoryError.historyCorrupt("stored head missing") }
    let data = try VersionedHistoryCodec.decompressed(blob, codec: row.codec, byteCount: row.byteCount)
    try verify(row, data: data)
    return data
  }

  private func insertHead(key: String, version: Int64, revision: Int64, value: Data, retention: Int?, createdAt: String) throws {
    let (blob, codec) = try VersionedHistoryCodec.compressed(value)
    let encoding = headStorage == .external ? "external" : "head"
    try sql.execute("""
      INSERT INTO \(versionsTable)(key,version,created_at,content_sha256,byte_count,encoding,anchor_version,codec,detached,blob)
      VALUES(?,?,?,?,?,?,?,?,0,?)
      """, [.text(key), .int(version), .text(createdAt), .text(VersionedHistoryCodec.sha256(value)), .int(Int64(value.count)),
        .text(encoding), .null, .text(headStorage == .external ? "none" : codec), headStorage == .external ? .null : .blob(blob)])
    try sql.execute("""
      INSERT INTO \(heads)(key,revision,head_version,retained_generations,updated_at) VALUES(?,?,?,?,?)
      ON CONFLICT(key) DO UPDATE SET revision=excluded.revision,head_version=excluded.head_version,
        retained_generations=COALESCE(excluded.retained_generations,\(heads).retained_generations),updated_at=excluded.updated_at
      """,
      [.text(key), .int(revision), .int(version), retention.map { .int(Int64($0)) } ?? .null, .text(timestamp())])
  }

  private func storeHeadAsVersion(key: String, version: Int64, value: Data, anchor: Data, anchorVersion: Int64) throws {
    let encodedValue = try encoded(value, against: anchor, detached: false)
    try sql.execute("UPDATE \(versionsTable) SET content_sha256=?,byte_count=?,encoding=?,anchor_version=?,codec=?,detached=0,blob=? WHERE key=? AND version=?",
      [.text(VersionedHistoryCodec.sha256(value)), .int(Int64(value.count)), .text(encodedValue.encoding),
       encodedValue.encoding == "delta" ? .int(anchorVersion) : .null, .text(encodedValue.codec), encodedValue.blob.map(VersionedHistorySQLValue.blob) ?? .null,
       .text(key), .int(version)])
  }

  private func setHeadRow(key: String, version: Int64, value: Data) throws {
    let (blob, codec) = try VersionedHistoryCodec.compressed(value)
    try sql.execute("UPDATE \(versionsTable) SET encoding=?,anchor_version=NULL,codec=?,detached=0,blob=? WHERE key=? AND version=?",
      [.text(headStorage == .external ? "external" : "head"), .text(headStorage == .external ? "none" : codec), headStorage == .external ? .null : .blob(blob), .text(key), .int(version)])
    try sql.execute("UPDATE \(versionsTable) SET content_sha256=?,byte_count=? WHERE key=? AND version=?",
      [.text(VersionedHistoryCodec.sha256(value)), .int(Int64(value.count)), .text(key), .int(version)])
  }

  private func store(row: Row, key: String, encoding: String, anchor: Data?, value: Data, detached: Bool, anchorVersion: Int64? = nil) throws {
    let encodedValue = try encoded(value, against: anchor, detached: detached)
    try sql.execute("UPDATE \(versionsTable) SET content_sha256=?,byte_count=?,encoding=?,anchor_version=?,codec=?,detached=?,blob=? WHERE key=? AND version=?",
      [.text(VersionedHistoryCodec.sha256(value)), .int(Int64(value.count)), .text(detached ? "full" : encodedValue.encoding),
       (detached ? nil : anchorVersion).map(VersionedHistorySQLValue.int) ?? .null,
       .text(encodedValue.codec), .int(detached ? 1 : (row.detached ? 1 : 0)), encodedValue.blob.map(VersionedHistorySQLValue.blob) ?? .null,
       .text(key), .int(row.version)])
    _ = encoding
  }

  private func encoded(_ value: Data, against anchor: Data?, detached: Bool) throws -> EncodedValue {
    guard let anchor, !detached else {
      let (blob, codec) = try VersionedHistoryCodec.compressed(value)
      return EncodedValue(encoding: "full", codec: codec, blob: blob)
    }
    let (full, fullCodec) = try VersionedHistoryCodec.compressed(value)
    let delta = VersionedHistoryCodec.splice(anchor, value)
    let (deltaBlob, deltaCodec) = try VersionedHistoryCodec.compressed(delta)
    return deltaBlob.count < full.count
      ? EncodedValue(encoding: "delta", codec: deltaCodec, blob: deltaBlob)
      : EncodedValue(encoding: "full", codec: fullCodec, blob: full)
  }

  private func rows(key: String) throws -> [Row] {
    try sql.query("""
      SELECT version,created_at,content_sha256,byte_count,encoding,anchor_version,codec,detached,blob,
        length(blob) AS stored_bytes FROM \(versionsTable) WHERE key=? ORDER BY version
      """, [.text(key)]).map(parseRow)
  }

  private func row(key: String, version: Int64) throws -> Row? {
    try sql.query("""
      SELECT version,created_at,content_sha256,byte_count,encoding,anchor_version,codec,detached,blob,
        length(blob) AS stored_bytes FROM \(versionsTable) WHERE key=? AND version=?
      """, [.text(key), .int(version)]).first.map(parseRow)
  }

  private func parseRow(_ values: [String: VersionedHistorySQLValue]) -> Row {
    Row(version: values.int("version"), createdAt: values.string("created_at"), hash: values.string("content_sha256"), byteCount: values.int("byte_count"),
        encoding: values.string("encoding"), anchor: values.optionalInt("anchor_version"), codec: values.string("codec"), detached: values.int("detached") != 0,
        blob: values.blob("blob"), storedBytes: values.int("stored_bytes"))
  }

  private func guardedDelete(key: String, version: Int64) throws {
    try withGuardedDelete { try sql.execute("DELETE FROM \(versionsTable) WHERE key=? AND version=?", [.text(key), .int(version)]) }
  }
  private func timestamp() -> String { ISO8601DateFormatter().string(from: now()) }
}

private extension Dictionary where Key == String, Value == VersionedHistorySQLValue {
  func string(_ key: String) -> String { if case let .text(value) = self[key] { return value }; return "" }
  func int(_ key: String) -> Int64 { if case let .int(value) = self[key] { return value }; return 0 }
  func optionalInt(_ key: String) -> Int64? { if case let .int(value) = self[key] { return value }; return nil }
  func blob(_ key: String) -> Data? { if case let .blob(value) = self[key] { return value }; return nil }
}
