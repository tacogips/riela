import ArgumentParser
import Foundation
import RielaMemory

struct ParsedCacheArguments: ParsableArguments {
  @Argument(help: "configure, put, get, keys, protect, reconcile, maintain, delete, or prune") var operation: String
  @Argument var cacheId: String
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
  @Option(help: "Fixed retrieval TTL in seconds, 1...31536000; configure only.") var ttlSeconds = 86_400
  @Option(help: "Total live charged-byte budget across all scopes; configure only.") var maxBytes = 268_435_456
  @Option var maxDurationSeconds = 120.0
  @Option var maxOutputBytes = RielaCacheStore.maximumFrameBytes
  @Option var output = "json"
}

struct CacheCommandRunner {
  static let operations = ["configure", "put", "get", "keys", "protect", "reconcile", "maintain", "delete", "prune"]

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
      try validateFlags(arguments, operation: parsed.operation)
      let store = RielaCacheStore(rootDirectory: parsed.cacheRoot)
      if parsed.operation == "keys" {
        let keys = try store.keys(cacheId: parsed.cacheId, scope: required(parsed.scope, "--scope"))
        let data = try JSONEncoder().encode(keys)
        return CLICommandResult(exitCode: .success, stdout: (String(data: data, encoding: .utf8) ?? "[]") + "\n")
      }
      if parsed.operation == "maintain" {
        let value = try store.maintain(cacheIds: decode([String].self, file: required(parsed.keysFile, "--keys-file")),
          maxDurationSeconds: parsed.maxDurationSeconds)
        let text = String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? "{}"
        return CLICommandResult(exitCode: .success, stdout: text + "\n")
      }
      let response: CacheResult
      switch parsed.operation {
      case "configure":
        response = try store.configure(cacheId: parsed.cacheId,
          policy: CachePolicy(ttlSeconds: parsed.ttlSeconds, maxBytes: parsed.maxBytes))
      case "prune": response = try store.prune(cacheId: parsed.cacheId)
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
        response = try store.put(cacheId: parsed.cacheId, scope: scope, entries: entries,
          retaining: try retained ?? parsed.referencesFile.map { try decode(MemoryJSONValue.self, file: $0) })
      case "reconcile":
        response = try store.reconcile(cacheId: parsed.cacheId, scope: required(parsed.scope, "--scope"),
          references: decode(MemoryJSONValue.self, file: required(parsed.referencesFile, "--references-file")))
      case "get":
        let keys: [String]
        if let file = parsed.keysFile {
          guard parsed.key == nil else { throw CLIUsageError("--keys-file cannot be combined with --key") }
          keys = try decode([String].self, file: file)
        } else { keys = [try required(parsed.key, "--key")] }
        response = try store.get(cacheId: parsed.cacheId, scope: required(parsed.scope, "--scope"),
          keys: keys, maxOutputBytes: parsed.maxOutputBytes)
      case "protect":
        response = try store.protect(cacheId: parsed.cacheId, scope: required(parsed.scope, "--scope"),
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
        response = try store.delete(cacheId: parsed.cacheId, scope: required(parsed.scope, "--scope"), entries: entries)
      default: throw CLIUsageError("cache operation must be configure, put, get, keys, protect, reconcile, maintain, delete, or prune")
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return CLICommandResult(exitCode: .success, stdout: (String(data: try encoder.encode(response), encoding: .utf8) ?? "{}") + "\n")
    } catch {
      let message = (error as? CLIUsageError)?.message ?? String(describing: error)
      let data = (try? JSONEncoder().encode(["error": message])) ?? Data()
      return CLICommandResult(exitCode: error is CLIUsageError ? .usage : .failure,
        stdout: (String(data: data, encoding: .utf8) ?? "{}") + "\n", stderr: "")
    }
  }

  private func validateFlags(_ arguments: [String], operation: String) throws {
    let common: Set<String> = ["--cache-root", "--output"]
    let options: [String: Set<String>] = [
      "configure": ["--ttl-seconds", "--max-bytes"],
      "keys": ["--scope"],
      "put": ["--scope", "--entries-file", "--key", "--fetched-at", "--payload-file", "--references-file", "--request-file"],
      "get": ["--scope", "--keys-file", "--key", "--max-output-bytes"],
      "protect": ["--scope", "--entries-file"],
      "reconcile": ["--scope", "--references-file"],
      "maintain": ["--keys-file", "--max-duration-seconds"],
      "delete": ["--scope", "--entries-file", "--key", "--expected-revision"],
      "prune": []
    ]
    let allowed = common.union(options[operation] ?? [])
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
