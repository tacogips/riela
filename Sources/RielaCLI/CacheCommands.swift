import ArgumentParser
import Foundation
import RielaMemory

struct ParsedCacheArguments: ParsableArguments {
  @Argument(help: "configure, put, get, keys, protect, reconcile, maintain, delete, or prune") var operation: String
  @Argument(help: "Cache id. Required except for maintain, which also accepts --cache-ids-file.") var cacheId: String?
  @Option var cacheRoot = RielaCacheStore.defaultRootDirectory()
  @Option var scope: String?
  @Option var key: String?
  @Option var fetchedAt: String?
  @Option var expectedRevision: String?
  @Option(help: "Committed reference metadata; use - for bounded stdin.") var referencesFile: String?
  @Option(help: "JSON {entries, retainedReferences}; use - for bounded stdin.") var requestFile: String?
  @Option var payloadFile: String?
  @Option(help: "JSON put/delete entry array; use - for bounded stdin.") var entriesFile: String?
  @Option(help: "JSON string array for batch get; use - for bounded stdin.") var keysFile: String?
  @Option(help: "JSON string array of cache ids; maintain only; use - for bounded stdin.") var cacheIdsFile: String?
  @Option(help: "Fixed retrieval TTL in seconds, 1...31536000; configure only.") var ttlSeconds = 86_400
  @Option(help: "Total live charged-byte budget across all scopes; configure only.") var maxBytes = 268_435_456
  @Option var maxDurationSeconds = 120.0
  @Option var maxOutputBytes = RielaCacheStore.maximumFrameBytes
  @Option var output = "json"
}

struct CacheCommandRunner {
  static let operations = ["configure", "put", "get", "keys", "protect", "reconcile", "maintain", "delete", "prune"]
  static let commonOptions: Set<String> = ["--cache-root", "--output"]
  /// Per-operation flags. SurfaceCatalog cache rows must list exactly these
  /// (plus the common options); CacheCommandTests enforces the agreement.
  static let operationOptions: [String: Set<String>] = [
    "configure": ["--ttl-seconds", "--max-bytes"],
    "keys": ["--scope"],
    "put": ["--scope", "--entries-file", "--key", "--fetched-at", "--payload-file", "--references-file", "--request-file"],
    "get": ["--scope", "--keys-file", "--key", "--max-output-bytes"],
    "protect": ["--scope", "--entries-file"],
    "reconcile": ["--scope", "--references-file"],
    "maintain": ["--cache-ids-file", "--max-duration-seconds"],
    "delete": ["--scope", "--entries-file", "--key", "--expected-revision"],
    "prune": []
  ]
  /// Operations that change a store's rows or policy. Built-in runtime cache ids
  /// (x-gateway-*) are refused here; keys/get stay available for inspection.
  static let reservedIdWriteOperations: Set<String> = ["configure", "put", "protect", "reconcile", "delete", "prune"]

  private static func encoded<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(data: try encoder.encode(value), encoding: .utf8) ?? "{}"
  }

  func run(_ arguments: [String]) -> CLICommandResult {
    if arguments.contains("--help") || arguments.contains("-h") {
      let help = ParsedCacheArguments.helpMessage().replacingOccurrences(of: "parsed_cache_arguments", with: "riela cache")
        .replacingOccurrences(of: "parsed-cache-arguments", with: "riela cache")
      return CLICommandResult(exitCode: .success, stdout: help + "\n")
    }
    do {
      let parsed: ParsedCacheArguments
      do { parsed = try ParsedCacheArguments.parse(arguments) } catch { throw CLIUsageError(ParsedCacheArguments.message(for: error)) }
      guard ["json", "jsonl"].contains(parsed.output) else { throw CLIUsageError("cache --output must be json or jsonl") }
      guard Self.operations.contains(parsed.operation) else {
        throw CLIUsageError("cache operation must be configure, put, get, keys, protect, reconcile, maintain, delete, or prune")
      }
      try validateFlags(arguments, operation: parsed.operation)
      let store = RielaCacheStore(rootDirectory: parsed.cacheRoot)
      if parsed.operation == "maintain" {
        let cacheIds: [String]
        if let file = parsed.cacheIdsFile {
          guard parsed.cacheId == nil else { throw CLIUsageError("cache maintain takes either <cache-id> or --cache-ids-file") }
          cacheIds = try decode([String].self, file: file)
        } else {
          cacheIds = [try required(parsed.cacheId, "<cache-id> or --cache-ids-file")]
        }
        let value = try store.maintain(cacheIds: cacheIds, maxDurationSeconds: parsed.maxDurationSeconds)
        // A failed store fails the command; deferred work (time budget, busy store) is not a failure.
        return CLICommandResult(exitCode: value.status == "failed" ? .failure : .success,
          stdout: try Self.encoded(value) + "\n")
      }
      let cacheId = try required(parsed.cacheId, "<cache-id>")
      if Self.reservedIdWriteOperations.contains(parsed.operation), RielaCacheStore.isReservedBuiltinCacheId(cacheId) {
        throw CLIUsageError("cacheId '\(cacheId)' is reserved for a built-in runtime cache")
      }
      if parsed.operation == "keys" {
        let keys = try store.keys(cacheId: cacheId, scope: required(parsed.scope, "--scope"))
        // json: one array; jsonl: one JSON string per key.
        let text = try parsed.output == "jsonl" ? keys.map { try Self.encoded($0) }.joined(separator: "\n") : Self.encoded(keys)
        return CLICommandResult(exitCode: .success, stdout: text.isEmpty ? "" : text + "\n")
      }
      let response: CacheResult
      switch parsed.operation {
      case "configure":
        response = try store.configure(cacheId: cacheId,
          policy: CachePolicy(ttlSeconds: parsed.ttlSeconds, maxBytes: parsed.maxBytes))
      case "prune": response = try store.prune(cacheId: cacheId)
      case "put":
        let scope = try required(parsed.scope, "--scope")
        let entries: [CachePut]
        var retained: MemoryJSONValue?
        if let file = parsed.requestFile {
          guard parsed.entriesFile == nil, parsed.referencesFile == nil, parsed.key == nil,
            parsed.payloadFile == nil, parsed.fetchedAt == nil else { throw CLIUsageError("--request-file cannot be combined with put input flags") }
          struct Request: Decodable { let entries: [CachePut]; let retainedReferences: MemoryJSONValue }
          let request = try decode(Request.self, file: file)
          entries = request.entries; retained = request.retainedReferences
        } else if let file = parsed.entriesFile {
          guard parsed.key == nil, parsed.payloadFile == nil, parsed.fetchedAt == nil else {
            throw CLIUsageError("--entries-file cannot be combined with single-entry options")
          }
          entries = try decode([CachePut].self, file: file)
        } else {
          entries = [CachePut(key: try required(parsed.key, "--key"),
            fetchedAt: try required(parsed.fetchedAt, "--fetched-at"),
            payload: try decode(MemoryJSONValue.self, file: required(parsed.payloadFile, "--payload-file")))]
        }
        response = try store.put(cacheId: cacheId, scope: scope, entries: entries,
          retaining: try retained ?? parsed.referencesFile.map { try decode(MemoryJSONValue.self, file: $0) })
      case "reconcile":
        response = try store.reconcile(cacheId: cacheId, scope: required(parsed.scope, "--scope"),
          references: decode(MemoryJSONValue.self, file: required(parsed.referencesFile, "--references-file")))
      case "get":
        let keys: [String]
        if let file = parsed.keysFile {
          guard parsed.key == nil else { throw CLIUsageError("--keys-file cannot be combined with --key") }
          keys = try decode([String].self, file: file)
        } else { keys = [try required(parsed.key, "--key")] }
        response = try store.get(cacheId: cacheId, scope: required(parsed.scope, "--scope"),
          keys: keys, maxOutputBytes: parsed.maxOutputBytes)
      case "protect":
        response = try store.protect(cacheId: cacheId, scope: required(parsed.scope, "--scope"),
          entries: decode([CacheProtection].self, file: required(parsed.entriesFile, "--entries-file")))
      case "delete":
        let entries: [CacheDelete]
        if let file = parsed.entriesFile {
          guard parsed.key == nil, parsed.expectedRevision == nil else {
            throw CLIUsageError("--entries-file cannot be combined with single-entry options")
          }
          entries = try decode([CacheDelete].self, file: file)
        } else {
          entries = [.init(key: try required(parsed.key, "--key"), revision: try required(parsed.expectedRevision, "--expected-revision"))]
        }
        response = try store.delete(cacheId: cacheId, scope: required(parsed.scope, "--scope"), entries: entries)
      default: throw CLIUsageError("cache operation must be configure, put, get, keys, protect, reconcile, maintain, delete, or prune")
      }
      return CLICommandResult(exitCode: .success, stdout: try Self.encoded(response) + "\n")
    } catch {
      let message = (error as? CLIUsageError)?.message ?? String(describing: error)
      let data = (try? JSONEncoder().encode(["error": message])) ?? Data()
      return CLICommandResult(exitCode: error is CLIUsageError ? .usage : .failure,
        stdout: (String(data: data, encoding: .utf8) ?? "{}") + "\n", stderr: "")
    }
  }

  private func validateFlags(_ arguments: [String], operation: String) throws {
    let allowed = Self.commonOptions.union(Self.operationOptions[operation] ?? [])
    for argument in arguments where argument.hasPrefix("--") {
      let flag = String(argument.split(separator: "=", maxSplits: 1)[0])
      guard allowed.contains(flag) else { throw CLIUsageError("\(flag) is not supported for cache \(operation)") }
    }
  }

  private func required(_ value: String?, _ flag: String) throws -> String {
    guard let value, !value.isEmpty else { throw CLIUsageError("cache requires \(flag)") }
    return value
  }

  private func decode<T: Decodable>(_ type: T.Type, file: String) throws -> T {
    let handle = try file == "-" ? FileHandle.standardInput : FileHandle(forReadingFrom: URL(fileURLWithPath: file))
    defer { if file != "-" { try? handle.close() } }
    var data = Data()
    let limit = RielaCacheStore.maximumFrameBytes
    while let chunk = try handle.read(upToCount: min(65_536, limit + 1 - data.count)), !chunk.isEmpty {
      data.append(chunk)
      guard data.count <= limit else { throw CLIUsageError("cache input exceeds 67108864 bytes") }
    }
    do { return try JSONDecoder().decode(type, from: data) } catch { throw CLIUsageError("invalid cache input JSON") }
  }
}
