import Foundation
import RielaCore

/// Each builtin owns validation and storage for its approved public metadata.
/// The private-workflow controller only transports registered, opted-in spaces.
protocol PrivateWorkflowCacheSpace: Sendable {
  func snapshot() -> JSONObject?
  func seed(_ value: JSONObject)
  func consume(_ payload: JSONValue) -> String
}

struct PrivateWorkflowCacheSpaces: Sendable {
  typealias Factory = @Sendable ([String: String]) -> any PrivateWorkflowCacheSpace
  static let registrations: [String: Factory] = [
    XGatewayUserCacheExchange.cacheId: { XUserPrivateCacheSpace(environment: $0) }
  ]
  static var registeredNames: Set<String> { Set(registrations.keys) }
  let spaces: [String: any PrivateWorkflowCacheSpace]
  var isEmpty: Bool { spaces.isEmpty }

  init(names: [String], environment: [String: String]) {
    spaces = Dictionary(uniqueKeysWithValues: Set(names).sorted().compactMap { name in
      Self.registrations[name].map { (name, $0(environment)) }
    })
  }

  func snapshot() -> [String: JSONObject] { spaces.compactMapValues { $0.snapshot() } }
  func seed(_ values: [String: JSONObject]) {
    for (name, value) in values { spaces[name]?.seed(value) }
  }
}

/// No arbitrary stderr is forwarded. Payload schemas belong to the registered
/// builtin; records and sizes are bounded independently of source output.
enum PrivateWorkflowCacheTransport {
  static let prefix = "riela-private-cache:"
  static let environmentKey = "RIELA_PRIVATE_CACHE_EXPORT"
  static let maximumLineBytes = 1_000_000
  private static let lock = NSLock()

  static func emit(cache: String, payload: JSONValue) {
    let enabled = ProcessInfo.processInfo.environment[environmentKey]?.split(separator: ",").map(String.init) ?? []
    guard enabled.contains(cache), PrivateWorkflowCacheSpaces.registeredNames.contains(cache),
      let text = line(cache: cache, payload: payload) else { return }
    lock.withLock { try? FileHandle.standardError.write(contentsOf: Data((text + "\n").utf8)) }
  }

  static func line(cache: String, payload: JSONValue) -> String? {
    guard let text = try? JSONValue.object(["cache": .string(cache), "payload": payload]).compactJSONString() else { return nil }
    let line = prefix + text
    return line.utf8.count <= maximumLineBytes ? line : nil
  }
}

final class PrivateWorkflowCacheExportCollector: @unchecked Sendable {
  private let spaces: PrivateWorkflowCacheSpaces
  private let seededSpaces: [String]
  private let lock = NSLock()
  private var admitted = 0
  private var dropped = 0
  private var receivedBytes = 0
  private var statuses: [String: Int] = [:]
  private let maximumRecords: Int
  private let maximumBytes: Int

  init(spaces: PrivateWorkflowCacheSpaces, seeds: [String: JSONObject], maximumRecords: Int = 64,
       maximumBytes: Int = 8_000_000) {
    self.spaces = spaces; self.seededSpaces = seeds.keys.sorted()
    self.maximumRecords = max(0, min(256, maximumRecords))
    self.maximumBytes = max(0, min(8_000_000, maximumBytes))
  }

  func accept(_ line: String) {
    guard !spaces.isEmpty, line.hasPrefix(PrivateWorkflowCacheTransport.prefix) else { return }
    lock.withLock {
      let size = line.utf8.count
      guard admitted < maximumRecords, size <= PrivateWorkflowCacheTransport.maximumLineBytes,
        size <= maximumBytes - receivedBytes else { dropped += 1; return }
      admitted += 1
      receivedBytes += size
      guard let bytes = String(line.dropFirst(PrivateWorkflowCacheTransport.prefix.count)).data(using: .utf8),
        let value = try? JSONDecoder().decode(JSONObject.self, from: bytes), Set(value.keys) == ["cache", "payload"],
        case let .string(name)? = value["cache"], let space = spaces.spaces[name], let payload = value["payload"] else {
        statuses["invalid", default: 0] += 1; return
      }
      statuses[space.consume(payload), default: 0] += 1
    }
  }

  var metadata: JSONObject {
    lock.withLock {
      ["seededSpaces": .array(seededSpaces.map(JSONValue.string)),
       "statuses": .object(statuses.mapValues { .integer(Int64($0)) }),
       "receivedRecords": .integer(Int64(admitted)), "droppedRecords": .integer(Int64(dropped)),
       "receivedBytes": .integer(Int64(receivedBytes))]
    }
  }
}
