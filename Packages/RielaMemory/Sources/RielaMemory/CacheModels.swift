import Foundation

public enum RielaCacheError: Error, Equatable, Sendable {
  case invalid(String)
  case oversized(bytes: Int, limit: Int)
  case expiredInput(String)
  case revisionConflict(String)
  case protectedCapacityExceeded(limit: Int)
  case foreignDatabase
  /// Another connection held the store past the busy timeout. Maintenance
  /// reports such a store as deferred rather than failed.
  case busy
}

public struct CachePolicy: Codable, Equatable, Sendable {
  public var ttlSeconds: Int
  public var maxBytes: Int
  public init(ttlSeconds: Int = 86_400, maxBytes: Int = 268_435_456) {
    self.ttlSeconds = ttlSeconds
    self.maxBytes = maxBytes
  }
  func validate() throws {
    guard (1...31_536_000).contains(ttlSeconds), (1...68_719_476_736).contains(maxBytes) else {
      throw RielaCacheError.invalid("ttlSeconds must be 1...31536000; maxBytes must be 1...68719476736")
    }
  }
}

public struct CachePut: Codable, Sendable {
  public var key: String
  public var fetchedAt: String
  public var payload: MemoryJSONValue
  public var protectFromEviction: Bool?
  public init(key: String, fetchedAt: String, payload: MemoryJSONValue, protectFromEviction: Bool? = nil) {
    self.key = key; self.fetchedAt = fetchedAt; self.payload = payload
    self.protectFromEviction = protectFromEviction
  }
}

public struct CacheProtection: Codable, Sendable {
  public var key: String
  public var revision: String
  public var protectFromEviction: Bool
  public init(key: String, revision: String, protectFromEviction: Bool) {
    self.key = key; self.revision = revision; self.protectFromEviction = protectFromEviction
  }
}

public struct CacheDelete: Codable, Sendable {
  public var key: String
  public var revision: String
  public init(key: String, revision: String) { self.key = key; self.revision = revision }
}

public struct CacheEntry: Codable, Equatable, Sendable {
  public var key: String
  public var scope: String
  public var revision: String
  public var fetchedAt: String
  public var expiresAt: String
  public var payload: MemoryJSONValue?
  public var byteCount: Int
  public var protectFromEviction: Bool?
}

public struct CacheLookup: Codable, Equatable, Sendable {
  public var key: String
  public var status: String
  public var reason: String?
  public var entry: CacheEntry?
}

public enum CacheReferenceStatus: String, Codable, Sendable {
  case hit, missing, expired
}

public struct CacheStats: Codable, Equatable, Sendable {
  public var entryCount: Int
  public var byteCount: Int
  public var expiredCount: Int
  public var evictedCount: Int
  public var policy: CachePolicy
  public var protectedByteCount: Int = 0
}

public struct CacheResult: Codable, Equatable, Sendable {
  public var results: [CacheLookup]
  public var deletedCount: Int
  public var stats: CacheStats
}

func cacheDate(_ value: String) -> Date? {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = formatter.date(from: value) { return date }
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.date(from: value)
}

func cacheTimestamp(_ milliseconds: Int64) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
}

/// Aggregate maintenance outcome. `status` is `failed` when any store failed,
/// `deferred` when a store was left for a later run (time budget or busy), and
/// `ok` otherwise. Missing, foreign, symlinked and hard-linked stores are
/// counted in `skippedCacheCount` and never opened for writing.
public struct CacheMaintenanceResult: Codable, Equatable, Sendable {
  /// At most this many failing cache ids are listed in `failedCacheIds`.
  public static let maximumReportedFailedCacheIds = 32
  public var status = "ok"
  public var cacheCount = 0
  public var failedCacheCount = 0
  public var failedCacheIds: [String] = []
  public var deferredCacheCount = 0
  public var skippedCacheCount = 0
  public var entryCount = 0
  public var byteCount = 0
  public var protectedByteCount = 0
  public var expiredEntryCount = 0
  public var evictedEntryCount = 0
  public init() {}
}
