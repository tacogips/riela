import Crypto
import Foundation

/// An inspected-body reference. Missing or replaced entries remain recoverable
/// work; this API never acknowledges provider IDs or advances their cursors.
public struct CacheBodyReference: Codable, Equatable, Sendable {
  public var key: String
  public var revision: String
  public var fetchedAt: String
  public var payloadSHA256: String
  public var byteCount: Int
  public var hashFormat: String?
  public var integritySHA256: String?

  private enum CodingKeys: String, CodingKey {
    case key, revision
    case fetchedAt = "fetched_at"
    case payloadSHA256 = "payload_sha256"
    case byteCount = "byte_count"
    case hashFormat = "hash_format"
    case integritySHA256 = "integrity_sha256"
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    key = try values.decode(String.self, forKey: .key)
    revision = try values.decode(String.self, forKey: .revision)
    fetchedAt = try values.decode(String.self, forKey: .fetchedAt)
    payloadSHA256 = try values.decode(String.self, forKey: .payloadSHA256)
    byteCount = try values.decodeIfPresent(Int.self, forKey: .byteCount) ?? RielaCacheStore.maximumFrameBytes
    hashFormat = try values.decodeIfPresent(String.self, forKey: .hashFormat)
    integritySHA256 = try values.decodeIfPresent(String.self, forKey: .integritySHA256)
  }

  public init(key: String, revision: String, fetchedAt: String, payloadSHA256: String,
              byteCount: Int, hashFormat: String? = "riela-json-v1") {
    self.key = key; self.revision = revision; self.fetchedAt = fetchedAt
    self.payloadSHA256 = payloadSHA256; self.byteCount = byteCount; self.hashFormat = hashFormat
    integritySHA256 = nil
  }
}

public struct CacheBodyRead: Codable, Equatable, Sendable {
  public var hits: [String: MemoryJSONValue] = [:]
  public var missing: [String] = []
  public var expired: [String] = []
  public init() {}
}

/// Bounded multi-batch admission/readback for disposable bodies or protected
/// staging, selected by the workflow rather than by provider/cache names.
public struct RielaCacheExchange: Sendable {
  public let store: RielaCacheStore
  public let cacheId: String
  public let scope: String
  public let policy: CachePolicy
  public let capacityProtection: Bool
  private static let frame = RielaCacheStore.maximumFrameBytes

  public init(store: RielaCacheStore, cacheId: String, scope: String,
              policy: CachePolicy = .init(ttlSeconds: 86_400, maxBytes: 10 * 1024 * 1024),
              capacityProtection: Bool = false) throws {
    try policy.validate()
    _ = try store.databasePath(cacheId: cacheId)
    guard !RielaCacheStore.isReservedBuiltinCacheId(cacheId), Self.validKey(scope), scope.utf8.count <= 512 else { throw Self.invalid() }
    self.store = store; self.cacheId = cacheId; self.scope = scope
    self.policy = policy; self.capacityProtection = capacityProtection
  }

  public func put(_ entries: [CachePut], retaining references: MemoryJSONValue? = nil) throws -> [String: CacheBodyReference] {
    guard entries.count <= 10_000, Set(entries.map(\.key)).count == entries.count else { throw Self.invalid() }
    // Validate every item before configuring, evicting or writing any batch.
    var batches: [[CachePut]] = [], batch: [CachePut] = []
    var charge = 0, total = 0
    let now = store.referenceDate()
    for var entry in entries {
      guard Self.validKey(entry.key), let date = cacheDate(entry.fetchedAt),
        date.timeIntervalSince1970 >= 0, date <= now, date.addingTimeInterval(Double(policy.ttlSeconds)) > now else { throw Self.invalid() }
      let bytes = try Self.encoded(entry.payload).count + entry.key.utf8.count + scope.utf8.count + 512
      guard bytes <= min(policy.maxBytes, Self.frame - 8192),
        try JSONEncoder().encode(entry).count <= Self.frame - 8192 else { throw Self.invalid() }
      total += bytes
      if !batch.isEmpty && (batch.count == 1024 || charge + bytes > min(policy.maxBytes, Self.frame / 2 - 65_536)) {
        batches.append(batch); batch = []; charge = 0
      }
      entry.protectFromEviction = capacityProtection && entry.protectFromEviction == true
      batch.append(entry); charge += bytes
    }
    if !batch.isEmpty { batches.append(batch) }
    guard !capacityProtection || total <= policy.maxBytes else { throw Self.invalid() }
    if entries.isEmpty { return [:] }
    _ = try store.configure(cacheId: cacheId, policy: policy)
    var result: [String: CacheBodyReference] = [:]
    for (index, batch) in batches.enumerated() {
      let response = try store.put(cacheId: cacheId, scope: scope, entries: batch,
        retaining: capacityProtection ? (index == 0 ? references : nil) : .array([]))
      let originals = Dictionary(uniqueKeysWithValues: batch.map { ($0.key, $0) })
      guard response.results.count == batch.count else { throw Self.invalid() }
      var current: [CacheBodyReference] = []
      for row in response.results {
        guard row.status == "stored", let entry = row.entry, entry.scope == scope,
          let original = originals[row.key], entry.key == original.key,
          cacheDate(entry.fetchedAt).map({ Int64(($0.timeIntervalSince1970 * 1000).rounded(.down)) })
            == cacheDate(original.fetchedAt).map({ Int64(($0.timeIntervalSince1970 * 1000).rounded(.down)) }) else { throw Self.invalid() }
        let ref = CacheBodyReference(key: entry.key, revision: entry.revision, fetchedAt: entry.fetchedAt,
          payloadSHA256: try Self.digest(original.payload), byteCount: entry.byteCount)
        result[row.key] = ref; current.append(ref)
      }
      // A later batch may evict this one. Its exact reference remains a miss,
      // never a false hit or an implicit acknowledgement.
      let checked = try get(current)
      guard checked.hits.count == batch.count, checked.missing.isEmpty, checked.expired.isEmpty else { throw Self.invalid() }
    }
    if capacityProtection {
      let checked = try get(Array(result.values))
      guard checked.hits.count == entries.count else { throw Self.invalid() }
    }
    return result
  }

  public func get(_ references: [CacheBodyReference]) throws -> CacheBodyRead {
    try validate(references)
    if references.isEmpty { return .init() }
    var found = CacheBodyRead()
    // Bound batches by bytes as well as count; storage bytes leave headroom
    // for SDK serialization. Do not prune before reading expired statuses.
    var batches: [[CacheBodyReference]] = [], batch: [CacheBodyReference] = [], charge = 0
    for ref in references {
      if !batch.isEmpty && (batch.count == 1024 || charge + ref.byteCount > Self.frame / 2 - 65_536) {
        batches.append(batch); batch = []; charge = 0
      }
      batch.append(ref); charge += ref.byteCount
    }
    if !batch.isEmpty { batches.append(batch) }
    var bytes = 0
    for batch in batches {
      let response = try store.get(cacheId: cacheId, scope: scope, keys: batch.map(\.key))
      let desired = Dictionary(uniqueKeysWithValues: batch.map { ($0.key, $0) })
      guard response.results.count == batch.count, Set(response.results.map(\.key)) == Set(desired.keys) else { throw Self.invalid() }
      for row in response.results {
        guard let ref = desired[row.key] else { throw Self.invalid() }
        if row.status == "miss", ["expired", "notFound"].contains(row.reason) {
          if row.reason == "expired" { found.expired.append(ref.key) } else { found.missing.append(ref.key) }
          continue
        }
        guard row.status == "hit", let entry = row.entry, entry.scope == scope,
          entry.key == ref.key, let payload = entry.payload else { throw Self.invalid() }
        guard entry.revision == ref.revision, cacheDate(entry.fetchedAt) == cacheDate(ref.fetchedAt),
          try revision(payload, key: ref.key, fetchedAt: entry.fetchedAt) == ref.revision else {
          found.missing.append(ref.key); continue
        }
        // A legacy Python domain hash has a different serializer. Its stored
        // revision still binds scope/key/fetch time/body cryptographically.
        // Domain adapters retain their additional original proof check.
        if let integrity = ref.integritySHA256 ?? (ref.hashFormat == "riela-json-v1" ? ref.payloadSHA256 : nil),
          try Self.digest(payload) != integrity { found.missing.append(ref.key); continue }
        bytes += try Self.encoded(payload).count + ref.key.utf8.count + 16
        guard bytes < Self.frame - 65_536 else { throw Self.invalid() }
        found.hits[ref.key] = payload
      }
    }
    guard try JSONEncoder().encode(found).count <= Self.frame - 4096 else { throw Self.invalid() }
    return found
  }

  public func protect(_ references: [CacheBodyReference], enabled: Bool) throws {
    try validate(references)
    guard !references.isEmpty else { return }
    _ = try store.configure(cacheId: cacheId, policy: policy)
    if !capacityProtection {
      // Release legacy protection across the owned scope. Evicted bodies are
      // expected and must not make a disposable-cache operation fail.
      _ = try store.reconcile(cacheId: cacheId, scope: scope, references: .array([]))
      return
    }
    for offset in stride(from: 0, to: references.count, by: 1024) {
      let batch = references[offset..<min(offset + 1024, references.count)]
      _ = try store.protect(cacheId: cacheId, scope: scope, entries: batch.map {
        .init(key: $0.key, revision: $0.revision, protectFromEviction: enabled)
      })
    }
  }

  public func reconcile(_ references: MemoryJSONValue) throws -> CacheResult {
    _ = try store.configure(cacheId: cacheId, policy: policy)
    return try store.reconcile(cacheId: cacheId, scope: scope, references: capacityProtection ? references : .array([]))
  }

  private func validate(_ references: [CacheBodyReference]) throws {
    guard references.count <= 10_000, Set(references.map(\.key)).count == references.count,
      references.allSatisfy({ Self.validKey($0.key) && cacheDate($0.fetchedAt) != nil &&
        (1...Self.frame).contains($0.byteCount) && [nil, "riela-json-v1"].contains($0.hashFormat) &&
        Self.validDigest($0.revision) && Self.validDigest($0.payloadSHA256) &&
        ($0.integritySHA256.map(Self.validDigest) ?? true) }) else { throw Self.invalid() }
  }

  private static func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private static func digest(_ value: MemoryJSONValue) throws -> String {
    SHA256.hash(data: try encoded(value)).map { String(format: "%02x", $0) }.joined()
  }

  private func revision(_ value: MemoryJSONValue, key: String, fetchedAt: String) throws -> String {
    var input = Data(scope.utf8); input.append(0)
    input.append(try Self.encoded(CachePut(key: key, fetchedAt: fetchedAt, payload: value)))
    return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
  }

  private static func validKey(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 1024 && value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
      !value.unicodeScalars.contains { $0.value < 32 }
  }

  private static func validDigest(_ value: String) -> Bool {
    value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
  }

  private static func invalid() -> RielaCacheError { .invalid("invalid cache exchange request or readback") }
}
