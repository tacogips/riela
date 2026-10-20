import Foundation
import RielaCore

public protocol RuntimeEnvironmentCommandRunning: Sendable {
  func run(source: RuntimeEnvironmentCommandSource, baseEnvironment: [String: String], maxOutputBytes: Int) async throws -> Data
}

/// Scope-local credentials. Nothing in this actor is persisted or exported.
public actor RuntimeEnvironmentSnapshotStore {
  private struct Entry {
    var configuration: RuntimeEnvironmentConfiguration
    var required: [String]
    var snapshot: RuntimeEnvironmentSnapshot
  }
  private var entries: [RuntimeEnvironmentScope: Entry] = [:]
  private var statuses: [RuntimeEnvironmentScope: RuntimeEnvironmentStatus] = [:]
  private var busy: Set<RuntimeEnvironmentScope> = []
  private struct Preparation {
    var id: UUID
    var configuration: RuntimeEnvironmentConfiguration
    var required: [String]
    var task: Task<RuntimeEnvironmentSnapshot, Error>
  }
  private var preparations: [RuntimeEnvironmentScope: Preparation] = [:]
  private let runner: any RuntimeEnvironmentCommandRunning
  private let maxOutputBytes: Int

  public init(runner: any RuntimeEnvironmentCommandRunning = RuntimeEnvironmentProcessRunner(), maxOutputBytes: Int = 1_048_576) {
    self.runner = runner; self.maxOutputBytes = maxOutputBytes
  }

  public func status(scope: RuntimeEnvironmentScope) -> RuntimeEnvironmentStatus {
    statuses[scope] ?? RuntimeEnvironmentStatus()
  }

  public func capture(scope: RuntimeEnvironmentScope) throws -> RuntimeEnvironmentSnapshot {
    guard let entry = entries[scope] else { throw RuntimeEnvironmentError.notPrepared }
    return entry.snapshot
  }

  public func prepare(scope: RuntimeEnvironmentScope, configuration: RuntimeEnvironmentConfiguration,
                      requiredNames: [String], baseEnvironment: [String: String]) async throws -> RuntimeEnvironmentSnapshot {
    let required = Array(Set(configuration.required + requiredNames)).sorted()
    if let entry = entries[scope], entry.configuration == configuration, entry.required == required {
      return try rebase(scope: scope, baseEnvironment: baseEnvironment)
    }
    if let pending = preparations[scope], pending.configuration == configuration, pending.required == required {
      _ = try await pending.task.value
      try Task.checkCancellation()
      return try rebase(scope: scope, baseEnvironment: baseEnvironment)
    }
    let id = UUID()
    let task = Task {
      _ = try await self.reload(scope: scope, configuration: configuration, requiredNames: requiredNames, baseEnvironment: baseEnvironment)
      return try self.capture(scope: scope)
    }
    preparations[scope] = Preparation(id: id, configuration: configuration, required: required, task: task)
    defer { if preparations[scope]?.id == id { preparations.removeValue(forKey: scope) } }
    _ = try await task.value
    try Task.checkCancellation()
    return try rebase(scope: scope, baseEnvironment: baseEnvironment)
  }

  private func rebase(scope: RuntimeEnvironmentScope, baseEnvironment: [String: String]) throws -> RuntimeEnvironmentSnapshot {
    guard var entry = entries[scope] else { throw RuntimeEnvironmentError.notPrepared }
    var environment = baseEnvironment
    let previous = entry.snapshot.runtimeEnvironment()
    for name in entry.configuration.sources.flatMap(\.names) { environment[name] = previous[name] }
    guard entry.required.allSatisfy({ !Self.empty(environment[$0]) }) else { throw RuntimeEnvironmentError.requiredMissing }
    if previous != environment {
      guard !busy.contains(scope) else { throw RuntimeEnvironmentError.sourceFailed }
      entry.snapshot = RuntimeEnvironmentSnapshot(generation: entry.snapshot.generation + 1, names: entry.snapshot.names, environment: environment)
      entries[scope] = entry
      if var status = statuses[scope] {
        status.generation = entry.snapshot.generation
        status.configuredNames = status.names.filter { !Self.empty(environment[$0]) }
        statuses[scope] = status
      }
    }
    return entry.snapshot
  }

  private static func empty(_ value: String?) -> Bool {
    value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
  }

  public func reload(scope: RuntimeEnvironmentScope, configuration: RuntimeEnvironmentConfiguration,
                     requiredNames: [String], baseEnvironment: [String: String],
                     install: (@Sendable (RuntimeEnvironmentSnapshot) async throws -> Void)? = nil) async throws -> RuntimeEnvironmentStatus {
    guard !busy.contains(scope) else { throw RuntimeEnvironmentError.sourceFailed }
    busy.insert(scope)
    defer { busy.remove(scope) }
    let required = Array(Set(configuration.required + requiredNames)).sorted()
    let names = Array(Set(required + configuration.sources.flatMap(\.names))).sorted()
    let generation = statuses[scope]?.generation ?? 0
    // A new descriptor must not accidentally execute with an old descriptor's values.
    if let old = entries[scope], old.configuration != configuration || old.required != required { entries.removeValue(forKey: scope) }
    var environment = baseEnvironment
    do {
      try validate(configuration, required: required)
      for source in configuration.sources {
        let data = try await runner.run(source: source, baseEnvironment: baseEnvironment, maxOutputBytes: maxOutputBytes)
        guard data.count <= maxOutputBytes else { throw RuntimeEnvironmentError.outputTooLarge }
        let loaded = try RuntimeEnvironmentOutput.decode(data, format: source.format)
        if source.format == .json, !Set(loaded.keys).isSubset(of: Set(source.names)) { throw RuntimeEnvironmentError.outputInvalid }
        for name in source.names {
          // Missing loader values remove any stale inherited value for that source.
          environment[name] = loaded[name]
        }
      }
      let missing = required.filter { Self.empty(environment[$0]) }
      guard missing.isEmpty else { throw RuntimeEnvironmentError.requiredMissing }
      let snapshot = RuntimeEnvironmentSnapshot(generation: generation + 1, names: names, environment: environment)
      // A parent may require its private child-pipe ACK before publication.
      // Failure preserves the last successful snapshot without a partial swap.
      if let install { try await install(snapshot) }
      entries[scope] = Entry(configuration: configuration, required: required, snapshot: snapshot)
      statuses[scope] = RuntimeEnvironmentStatus(names: names, configuredNames: names.filter { !Self.empty(environment[$0]) },
        sourceIDs: configuration.sources.map(\.id), generation: snapshot.generation, readiness: .ready)
      return statuses[scope]!
    } catch {
      let safe = error as? RuntimeEnvironmentError ?? .sourceFailed
      let previous = entries[scope]?.snapshot
      statuses[scope] = RuntimeEnvironmentStatus(names: names,
        configuredNames: previous.map { snapshot in names.filter { !Self.empty(snapshot.runtimeEnvironment()[$0]) } } ?? [],
        missingNames: previous == nil ? required.filter { Self.empty(environment[$0]) } : [],
        sourceIDs: configuration.sources.map(\.id), generation: generation,
        readiness: previous == nil ? .failed : .ready, lastError: safe)
      if error is CancellationError { throw CancellationError() }
      throw safe
    }
  }

  private func validate(_ configuration: RuntimeEnvironmentConfiguration, required: [String]) throws {
    guard maxOutputBytes > 0, maxOutputBytes <= 16_777_216,
      required.allSatisfy(isValidEnvironmentVariableName),
      Set(configuration.sources.map(\.id)).count == configuration.sources.count else { throw RuntimeEnvironmentError.invalidConfiguration }
    var declared = Set<String>()
    for source in configuration.sources {
      guard !source.id.isEmpty, !source.command.isEmpty, source.command.allSatisfy({ !$0.contains("\0") }),
        !source.command[0].isEmpty, !source.names.isEmpty, source.names.allSatisfy(isValidEnvironmentVariableName),
        source.timeoutSeconds.isFinite, source.timeoutSeconds > 0, source.timeoutSeconds <= 300 else { throw RuntimeEnvironmentError.invalidConfiguration }
      for name in source.names where !declared.insert(name).inserted { throw RuntimeEnvironmentError.invalidConfiguration }
    }
  }
}

enum RuntimeEnvironmentOutput {
  static func decode(_ data: Data, format: RuntimeEnvironmentCommandSource.Format) throws -> [String: String] {
    var result: [String: String] = [:]
    func insert(_ key: String, _ value: String) throws {
      guard isValidEnvironmentVariableName(key), result[key] == nil, !value.contains("\0") else { throw RuntimeEnvironmentError.outputInvalid }
      result[key] = value
    }
    if format == .env0 {
      guard data.last == 0 else { throw RuntimeEnvironmentError.outputInvalid }
      for record in data.dropLast().split(separator: 0, omittingEmptySubsequences: false) {
        guard let text = String(data: Data(record), encoding: .utf8), let separator = text.firstIndex(of: "=") else { throw RuntimeEnvironmentError.outputInvalid }
        try insert(String(text[..<separator]), String(text[text.index(after: separator)...]))
      }
      return result
    }
    // Parse the flat string dictionary directly: JSONSerialization silently
    // accepts duplicate keys, which must instead be an explicit loader error.
    let bytes = Array(data); var index = 0
    func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    func string() throws -> String {
      whitespace(); let start = index
      guard index < bytes.count, bytes[index] == 34 else { throw RuntimeEnvironmentError.outputInvalid }
      index += 1
      while index < bytes.count {
        let byte = bytes[index]; index += 1
        if byte == 92 { guard index < bytes.count else { break }; index += 1 } else if byte == 34 {
          guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else { throw RuntimeEnvironmentError.outputInvalid }
          return value
        }
      }
      throw RuntimeEnvironmentError.outputInvalid
    }
    whitespace(); guard index < bytes.count, bytes[index] == 123 else { throw RuntimeEnvironmentError.outputInvalid }; index += 1
    whitespace()
    if index < bytes.count && bytes[index] != 125 {
      while true {
        let key = try string(); whitespace()
        guard index < bytes.count, bytes[index] == 58 else { throw RuntimeEnvironmentError.outputInvalid }; index += 1
        try insert(key, string()); whitespace()
        guard index < bytes.count else { throw RuntimeEnvironmentError.outputInvalid }
        if bytes[index] == 125 { break }
        guard bytes[index] == 44 else { throw RuntimeEnvironmentError.outputInvalid }; index += 1
      }
    }
    guard index < bytes.count, bytes[index] == 125 else { throw RuntimeEnvironmentError.outputInvalid }; index += 1; whitespace()
    guard index == bytes.count else { throw RuntimeEnvironmentError.outputInvalid }
    return result
  }
}
