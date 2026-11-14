import Crypto
import Foundation

/// A byte-exact reverse patch. Apply only to `fromVersion` (the newer version)
/// to reconstruct `toVersion` (its immediate predecessor).
public struct EvolutionReverseDelta: Codable, Equatable, Sendable {
  public enum Direction: String, Codable, Sendable {
    case nextToPrevious = "next-to-previous"
  }

  public enum ValidationError: Error, Equatable {
    case unsupportedFormat
    case invalidVersion
    case invalidRange
    case sourceMismatch
    case resultMismatch
  }

  public let schemaVersion: Int
  public let direction: Direction
  public let fromVersion: Int64
  public let toVersion: Int64
  public let fromSHA256: String
  public let toSHA256: String
  public let fromByteCount: Int
  public let toByteCount: Int
  /// Offset and lengths are bytes, never Unicode character offsets.
  public let prefixByteCount: Int
  public let suffixByteCount: Int
  /// JSON encodes this as base64; arbitrary binary and invalid UTF-8 round-trip.
  public let previousMiddle: Data

  /// Linear time and bounded auxiliary memory; unchanged prefix/suffix bytes
  /// are not persisted. Multiple distant edits may retain the intervening bytes.
  public init(previous: Data, next: Data, nextVersion: Int64) throws {
    guard nextVersion > 1 else { throw ValidationError.invalidVersion }
    schemaVersion = 1
    direction = .nextToPrevious
    fromVersion = nextVersion
    toVersion = nextVersion - 1
    fromSHA256 = Self.digest(next)
    toSHA256 = Self.digest(previous)
    fromByteCount = next.count
    toByteCount = previous.count
    let old = [UInt8](previous)
    let new = [UInt8](next)
    let commonLimit = min(old.count, new.count)
    var prefix = 0
    while prefix < commonLimit, old[prefix] == new[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < commonLimit - prefix,
      old[old.count - suffix - 1] == new[new.count - suffix - 1] {
      suffix += 1
    }
    prefixByteCount = prefix
    suffixByteCount = suffix
    previousMiddle = Data(old[prefix..<(old.count - suffix)])
  }

  public func reconstructPrevious(from next: Data, version: Int64) throws -> Data {
    guard schemaVersion == 1 else { throw ValidationError.unsupportedFormat }
    guard fromVersion > 1, toVersion == fromVersion - 1, version == fromVersion else {
      throw ValidationError.invalidVersion
    }
    guard fromByteCount >= 0, toByteCount >= 0,
      prefixByteCount >= 0, suffixByteCount >= 0,
      prefixByteCount <= fromByteCount, suffixByteCount <= fromByteCount - prefixByteCount,
      prefixByteCount <= toByteCount, suffixByteCount <= toByteCount - prefixByteCount,
      previousMiddle.count == toByteCount - prefixByteCount - suffixByteCount else {
      throw ValidationError.invalidRange
    }
    guard next.count == fromByteCount, Self.digest(next) == fromSHA256 else {
      throw ValidationError.sourceMismatch
    }
    var result = Data(next.prefix(prefixByteCount))
    result.append(previousMiddle)
    result.append(contentsOf: next.suffix(suffixByteCount))
    guard result.count == toByteCount, Self.digest(result) == toSHA256 else {
      throw ValidationError.resultMismatch
    }
    return result
  }

  private static func digest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
}
