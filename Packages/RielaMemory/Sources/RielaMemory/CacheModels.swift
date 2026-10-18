import Foundation

public enum RielaCacheError: Error, Equatable, Sendable {
  case invalid(String)
  case oversized(bytes: Int, limit: Int)
  case expiredInput(String)
  case revisionConflict(String)
  case foreignDatabase
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
  public init(key: String, fetchedAt: String, payload: MemoryJSONValue) {
    self.key = key; self.fetchedAt = fetchedAt; self.payload = payload
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
}

public struct CacheLookup: Codable, Equatable, Sendable {
  public var key: String
  public var status: String
  public var reason: String?
  public var entry: CacheEntry?
}

public struct CacheStats: Codable, Equatable, Sendable {
  public var entryCount: Int
  public var byteCount: Int
  public var expiredCount: Int
  public var evictedCount: Int
  public var policy: CachePolicy
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
