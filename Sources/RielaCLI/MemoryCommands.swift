import Foundation
import RielaCore
import RielaMemory

public struct MemorySaveCommandResult: Codable, Equatable, Sendable {
  public var memoryId: String
  public var databasePath: String
  public var record: MemoryRecord
}

public struct MemoryUpdateCommandResult: Codable, Equatable, Sendable {
  public var memoryId: String
  public var databasePath: String
  public var updated: Bool
  public var record: MemoryRecord
}

public struct MemoryHistoryDiffEntry: Codable, Equatable, Sendable {
  public var path: String
  public var op: String
  public var before: JSONValue?
  public var after: JSONValue?
  public var encoding: String?
  public var beforeSHA256: String?
  public var afterSHA256: String?
  public var beforeByteCount: Int64?
  public var afterByteCount: Int64?
  public var prefixByteCount: Int64?
  public var suffixByteCount: Int64?
}

public struct MemoryShowVersionDiffResult: Codable, Equatable, Sendable {
  public var record: MemoryRecord
  public var diff: [MemoryHistoryDiffEntry]
}

public struct MemorySearchCommandResult: Codable, Equatable, Sendable {
  public var memoryId: String
  public var databasePath: String
  public var workflowId: String?
  public var allWorkflows: Bool
  public var nodeId: String?
  public var matchPatterns: [String]
  public var tags: [String]
  public var relatedRecordIds: [Int64]
  public var limit: Int
  public var maxPayloadBytes: Int
  public var records: [MemoryRecord]
}

public struct MemoryMetadataCommandResult: Codable, Equatable, Sendable {
  public var memoryId: String
  public var databasePath: String
  public var metadata: MemoryMetadata?
}

public struct MemoryValuesCommandResult<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
  public var memoryId: String
  public var databasePath: String
  public var workflowId: String?
  public var allWorkflows: Bool
  public var sortOrder: MemoryValueSortOrder
  public var limit: Int
  public var offset: Int
  public var values: [Value]
}

public struct MemoryCommandRunner: Sendable {
  public init() {}

  public func run(_ command: MemoryCommand) -> CLICommandResult {
    do {
      switch command.kind {
      case .save:
        return try save(command.options)
      case .update:
        return try update(command.options)
      case .load:
        return try list(command.options, matchPatterns: [], overflowPolicy: .fail)
      case .search:
        return try list(command.options, matchPatterns: command.options.matchPatterns)
      case .metadata:
        return try metadata(command.options)
      case .tags:
        return try tags(command.options)
      case .relatedIds:
        return try relatedIds(command.options)
      case .retireHistory:
        return try retireHistory(command.options)
      case .undo, .redo:
        return try moveHistoryHead(command)
      case .history, .showVersion, .restoreVersion:
        return try evolution(command)
      }
    } catch let error as CLIUsageError {
      return failure(error.message, output: command.options.output, options: command.options.cliOptions)
    } catch let error as VersionedHistoryError {
      return failure(historyErrorMessage(error), output: command.options.output, options: command.options.cliOptions)
    } catch let error as MemoryEvolutionError {
      let message: String
      if case let .staleHead(expected, actual) = error {
        message = "stale_revision: expected head revision \(expected), actual \(actual)"
      } else {
        message = "\(error)"
      }
      return failure(message, output: command.options.output, options: command.options.cliOptions)
    } catch let error as RielaMemoryError {
      let message: String
      if case let .invalidHistoryRetention(value) = error {
        message = "invalid_history_retention: history retention \(value) must be in 1...1000"
      } else {
        message = "\(error)"
      }
      return failure(message, output: command.options.output, options: command.options.cliOptions)
    } catch {
      return failure("\(error)", output: command.options.output, options: command.options.cliOptions)
    }
  }

  private func retireHistory(_ options: MemoryCommandOptions) throws -> CLICommandResult {
    guard let recordId = options.recordId, let workflowId = options.workflowId,
      let nodeId = options.nodeId, let head = options.expectedHeadVersion,
      let through = options.throughVersion, let root = options.databaseRoot,
      root.hasPrefix("/"), !options.tags.isEmpty, !options.allWorkflows else {
      throw CLIUsageError("retire-history requires explicit absolute --memory-root, --record-id, --workflow-id, --node-id, --tag, --expected-head-version and --through-version")
    }
    let report = try memoryStore(options).retireHistory(memoryId: options.memoryId, recordId: recordId,
      workflowId: workflowId, nodeId: nodeId, requiredTags: options.tags,
      expectedHeadVersion: head, throughVersion: through, dryRun: options.dryRun)
    return try render(report, output: options.output) { $0.status + "\n" }
  }

  private func evolution(_ command: MemoryCommand) throws -> CLICommandResult {
    let options = command.options
    guard let recordId = options.recordId else { throw CLIUsageError("memory history commands require --record-id") }
    let store = memoryStore(options)
    if command.kind == .history {
      let history = try store.evolutionHistory(memoryId: options.memoryId, recordId: recordId,
        limit: options.limit, beforeVersion: options.beforeVersion)
      return try render(history, output: options.output) { revisions in
        var lines = revisions.map { revision -> String in
          if let storage = revision.storage {
            let head = revision.isHead == true ? " head revision \(revision.revision ?? 0)" : ""
            return "version \(revision.version) \(revision.recordedAt)\(head) \(storage.encoding) \(storage.storedBytes)B"
          }
          return "version \(revision.version) \(revision.recordedAt) \(revision.reverseDelta?.direction.rawValue ?? "baseline")"
        }
        if let oldest = revisions.map(\.version).min(), oldest > 1, revisions.contains(where: { $0.storage != nil }) {
          lines.append("older versions dropped by retention (retained: \(oldest)...head)")
        }
        return lines.joined(separator: "\n") + "\n"
      }
    }
    guard let version = options.version else { throw CLIUsageError("memory version commands require --version") }
    if command.kind == .showVersion, let diffAgainst = options.diffAgainst {
      let record = try retainedRecordVersion(store: store, memoryId: options.memoryId, recordId: recordId, version: version)
      let toVersion: Int64? = diffAgainst == "head" ? nil : Int64(diffAgainst)
      let entries = try store.recordDiff(memoryId: options.memoryId, recordId: recordId,
        fromVersion: version, toVersion: toVersion).map(memoryHistoryDiffEntry)
      let result = MemoryShowVersionDiffResult(record: record, diff: entries)
      return try render(result, output: options.output) { _ in
        let rows = entries.map { entry in
          let before = entry.before.map(compactJSONValue) ?? "<absent>"
          let after = entry.after.map(compactJSONValue) ?? "<absent>"
          return "\(entry.op) \(entry.path)\nbefore: \(before)\nafter: \(after)"
        }
        return "show-version memory \(options.memoryId) record \(recordId) version \(version) diff\n" + rows.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
      }
    }
    let record: MemoryRecord
    if command.kind == .restoreVersion {
      guard let head = options.expectedHeadVersion else {
        throw CLIUsageError("memory restore-version requires --expected-head-version (read memory history first)")
      }
      do {
        record = try store.restoreRecordVersion(memoryId: options.memoryId, recordId: recordId,
          version: version, expectedHeadVersion: head, historyRetention: options.historyRetention)
      } catch MemoryHistoryRetirementError.retiredVersion {
        throw legacyVersionNotRetainedError(store: store, memoryId: options.memoryId, recordId: recordId, version: version)
      } catch EvolutionReverseDelta.ValidationError.invalidVersion {
        throw legacyVersionNotRetainedError(store: store, memoryId: options.memoryId, recordId: recordId, version: version)
      }
    } else {
      record = try retainedRecordVersion(store: store, memoryId: options.memoryId, recordId: recordId, version: version)
    }
    return try render(record, output: options.output) { record in
      "\(command.kind.rawValue) memory \(record.memoryId) record \(record.recordId) version \(version)\n\(compactPayload(record.payload))\n"
    }
  }

  private func moveHistoryHead(_ command: MemoryCommand) throws -> CLICommandResult {
    let options = command.options
    guard let recordId = options.recordId else {
      throw CLIUsageError("memory \(command.kind.rawValue) requires --record-id")
    }
    guard let expectedRevision = options.expectedHeadVersion else {
      throw CLIUsageError("memory \(command.kind.rawValue) requires --expected-head-version (read memory history first)")
    }
    let store = memoryStore(options)
    let result = try command.kind == .undo
      ? store.undoRecord(memoryId: options.memoryId, recordId: recordId, expectedHeadVersion: expectedRevision)
      : store.redoRecord(memoryId: options.memoryId, recordId: recordId, expectedHeadVersion: expectedRevision)
    return try render(result, output: options.output) { result in
      "\(command.kind.rawValue) memory \(result.record.memoryId) record \(result.record.recordId) from version \(result.fromVersion) to \(result.headVersion) revision \(result.revision)\n"
    }
  }

  private func save(_ options: MemoryCommandOptions) throws -> CLICommandResult {
    let workflowId = try requiredWorkflowId(options)
    let store = memoryStore(options)
    let payload = try payloadValue(options)
    let record = try store.save(
      memoryId: options.memoryId,
      workflowId: workflowId,
      nodeId: options.nodeId,
      registeredAt: options.registeredAt,
      tags: options.tags,
      relatedRecordIds: options.relatedRecordIds,
      files: memoryFileReferences(options),
      payload: payload,
      historyRetention: options.historyRetention
    )
    let result = MemorySaveCommandResult(
      memoryId: options.memoryId,
      databasePath: try store.databasePath(memoryId: options.memoryId),
      record: record
    )
    return try render(result, output: options.output) { result in
      "saved memory \(result.memoryId) record \(result.record.recordId) for workflow \(result.record.workflowId)\n"
    }
  }

  private func update(_ options: MemoryCommandOptions) throws -> CLICommandResult {
    guard let recordId = options.recordId else {
      throw CLIUsageError("memory update requires --record-id")
    }
    guard let workflowId = options.workflowId else {
      throw CLIUsageError("memory update requires --workflow-id")
    }
    let store = memoryStore(options)
    let payload = try payloadValue(options)
    let record = try store.update(
      memoryId: options.memoryId,
      recordId: recordId,
      workflowId: workflowId,
      nodeId: options.nodeId,
      tags: options.tags,
      relatedRecordIds: options.relatedRecordIds,
      files: memoryUpdateFileReferences(options),
      payload: payload,
      historyRetention: options.historyRetention
    )
    let result = MemoryUpdateCommandResult(
      memoryId: options.memoryId,
      databasePath: try store.databasePath(memoryId: options.memoryId),
      updated: true,
      record: record
    )
    return try render(result, output: options.output) { result in
      "updated memory \(result.memoryId) record \(result.record.recordId) for workflow \(result.record.workflowId)\n"
    }
  }

  private func retainedRecordVersion(
    store: RielaMemoryStore,
    memoryId: String,
    recordId: Int64,
    version: Int64
  ) throws -> MemoryRecord {
    do {
      return try store.recordVersion(memoryId: memoryId, recordId: recordId, version: version)
    } catch MemoryHistoryRetirementError.retiredVersion {
      throw legacyVersionNotRetainedError(store: store, memoryId: memoryId, recordId: recordId, version: version)
    } catch EvolutionReverseDelta.ValidationError.invalidVersion {
      throw legacyVersionNotRetainedError(store: store, memoryId: memoryId, recordId: recordId, version: version)
    }
  }

  private func list(_ options: MemoryCommandOptions, matchPatterns: [String], overflowPolicy: MemoryPayloadOverflowPolicy = .skip) throws -> CLICommandResult {
    guard (1...67_108_864).contains(options.maxPayloadBytes) else {
      throw CLIUsageError("--max-payload-bytes must be an integer in 1...67108864")
    }
    let workflowId = options.workflowId ?? "*"
    let store = memoryStore(options)
    let records = try store.search(
      memoryId: options.memoryId,
      options: MemorySearchOptions(
        workflowId: workflowId,
        includeAllWorkflows: options.allWorkflows,
        nodeId: options.nodeId,
        matchPatterns: matchPatterns,
        tags: options.tags,
        relatedRecordIds: options.relatedRecordIds,
        limit: options.limit,
        maxPayloadBytes: options.maxPayloadBytes,
        payloadOverflowPolicy: overflowPolicy
      )
    )
    let result = MemorySearchCommandResult(
      memoryId: options.memoryId,
      databasePath: try store.databasePath(memoryId: options.memoryId),
      workflowId: options.workflowId,
      allWorkflows: options.allWorkflows,
      nodeId: options.nodeId,
      matchPatterns: matchPatterns,
      tags: options.tags,
      relatedRecordIds: options.relatedRecordIds,
      limit: options.limit,
      maxPayloadBytes: options.maxPayloadBytes,
      records: records
    )
    return try render(result, output: options.output) { result in
      result.records.map { record in
        "\(record.registeredAt) \(record.workflowId) \(record.nodeId ?? "-") #\(record.recordId) \(compactPayload(record.payload))"
      }.joined(separator: "\n") + (result.records.isEmpty ? "" : "\n")
    }
  }

  private func metadata(_ options: MemoryCommandOptions) throws -> CLICommandResult {
    let store = memoryStore(options)
    let result = MemoryMetadataCommandResult(
      memoryId: options.memoryId,
      databasePath: try store.databasePath(memoryId: options.memoryId),
      metadata: try store.metadata(memoryId: options.memoryId)
    )
    return try render(result, output: options.output) { result in
      guard let metadata = result.metadata else {
        return ""
      }
      return [
        "memoryId: \(metadata.memoryId)",
        metadata.description.map { "description: \($0)" },
        metadata.purpose.map { "purpose: \($0)" },
        "updatedAt: \(metadata.updatedAt)"
      ].compactMap(\.self).joined(separator: "\n") + "\n"
    }
  }

  private func tags(_ options: MemoryCommandOptions) throws -> CLICommandResult {
    let store = memoryStore(options)
    let values = try store.uniqueTags(memoryId: options.memoryId, options: valueListOptions(options))
    let result = MemoryValuesCommandResult<String>(
      memoryId: options.memoryId,
      databasePath: try store.databasePath(memoryId: options.memoryId),
      workflowId: options.workflowId,
      allWorkflows: options.allWorkflows,
      sortOrder: options.sortOrder,
      limit: options.limit,
      offset: options.offset,
      values: values
    )
    return try render(result, output: options.output) { result in
      result.values.joined(separator: "\n") + (result.values.isEmpty ? "" : "\n")
    }
  }

  private func relatedIds(_ options: MemoryCommandOptions) throws -> CLICommandResult {
    let store = memoryStore(options)
    let values = try store.uniqueRelatedRecordIds(memoryId: options.memoryId, options: valueListOptions(options))
    let result = MemoryValuesCommandResult<Int64>(
      memoryId: options.memoryId,
      databasePath: try store.databasePath(memoryId: options.memoryId),
      workflowId: options.workflowId,
      allWorkflows: options.allWorkflows,
      sortOrder: options.sortOrder,
      limit: options.limit,
      offset: options.offset,
      values: values
    )
    return try render(result, output: options.output) { result in
      result.values.map(String.init).joined(separator: "\n") + (result.values.isEmpty ? "" : "\n")
    }
  }

  private func memoryStore(_ options: MemoryCommandOptions) -> RielaMemoryStore {
    let root = options.databaseRoot ?? RielaMemoryStore.defaultRootDirectory(workingDirectory: options.workingDirectory)
    return RielaMemoryStore(rootDirectory: root)
  }

  private func requiredWorkflowId(_ options: MemoryCommandOptions) throws -> String {
    guard let workflowId = options.workflowId, !workflowId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CLIUsageError("memory command requires --workflow-id")
    }
    return workflowId
  }

  private func payloadValue(_ options: MemoryCommandOptions) throws -> MemoryJSONValue {
    if let payloadJSON = options.payloadJSON {
      return try decodePayload(payloadJSON)
    }
    if let payloadFile = options.payloadFile {
      let url = absoluteURL(payloadFile, relativeTo: URL(fileURLWithPath: options.workingDirectory, isDirectory: true))
      let data = try Data(contentsOf: url)
      guard let string = String(data: data, encoding: .utf8) else {
        throw CLIUsageError("memory payload file is not UTF-8: \(payloadFile)")
      }
      return try decodePayload(string)
    }
    throw CLIUsageError("memory command requires --payload-json or --payload-file")
  }

  private func memoryFileReferences(_ options: MemoryCommandOptions) -> [MemoryFileReference] {
    options.filePaths.map { path in
      let url = absoluteURL(path, relativeTo: URL(fileURLWithPath: options.workingDirectory, isDirectory: true))
      return MemoryFileReference(path: url.path)
    }
  }

  private func memoryUpdateFileReferences(_ options: MemoryCommandOptions) -> [MemoryFileReference]? {
    if options.clearFiles {
      return []
    }
    let references = memoryFileReferences(options)
    return references.isEmpty ? nil : references
  }

  private func decodePayload(_ json: String) throws -> MemoryJSONValue {
    do {
      return try JSONDecoder().decode(MemoryJSONValue.self, from: Data(json.utf8))
    } catch {
      throw CLIUsageError("memory payload must be valid JSON: \(error.localizedDescription)")
    }
  }

  private func render<T: Encodable>(
    _ result: T,
    output: WorkflowOutputFormat,
    text: (T) -> String
  ) throws -> CLICommandResult {
    switch output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: .success, stdout: try jsonString(result))
    case .text, .table:
      return CLICommandResult(exitCode: .success, stdout: text(result))
    }
  }

  private func valueListOptions(_ options: MemoryCommandOptions) -> MemoryValueListOptions {
    MemoryValueListOptions(
      workflowId: options.workflowId,
      includeAllWorkflows: options.allWorkflows,
      sortOrder: options.sortOrder,
      limit: options.limit,
      offset: options.offset
    )
  }
}

private extension MemoryCommandOptions {
  var cliOptions: CLICommandOptions {
    CLICommandOptions(
      scope: "memory",
      command: nil,
      target: memoryId,
      arguments: [],
      output: output
    )
  }
}

private func compactPayload(_ payload: MemoryJSONValue) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  guard
    let data = try? encoder.encode(payload),
    let text = String(data: data, encoding: .utf8)
  else {
    return "<payload>"
  }
  return text
}

private func compactJSONValue(_ value: JSONValue) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "null" }
  return text
}

private func memoryHistoryDiffEntry(_ entry: VersionedHistoryDiffEntry) -> MemoryHistoryDiffEntry {
  MemoryHistoryDiffEntry(
    path: entry.path,
    op: entry.op,
    before: entry.beforeJSON.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) },
    after: entry.afterJSON.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) },
    encoding: entry.encoding,
    beforeSHA256: entry.beforeSHA256,
    afterSHA256: entry.afterSHA256,
    beforeByteCount: entry.beforeByteCount,
    afterByteCount: entry.afterByteCount,
    prefixByteCount: entry.prefixByteCount,
    suffixByteCount: entry.suffixByteCount
  )
}

private func historyErrorMessage(_ error: VersionedHistoryError) -> String {
  switch error {
  case let .versionNotRetained(version, retained, _):
    let versions = retained.map(String.init).joined(separator: ", ")
    return "version_not_retained: version \(version) is not retained; retained versions: [\(versions)] (dropped by retention or never a stored version)"
  case let .nothingToUndo(oldestRetained):
    return "nothing_to_undo: no older retained version before \(oldestRetained)"
  case .nothingToRedo:
    return "nothing_to_redo: no newer retained version"
  case let .staleRevision(expected, actual):
    return "stale_revision: expected head revision \(expected), actual \(actual)"
  case let .historyCorrupt(message):
    return "history_corrupt: \(message)"
  case let .invalidRetention(value):
    return "invalid_history_retention: history retention \(value) must be in 1...1000"
  }
}

private func legacyVersionNotRetainedError(
  store: RielaMemoryStore,
  memoryId: String,
  recordId: Int64,
  version: Int64
) -> CLIUsageError {
  let retained = (try? store.evolutionHistory(memoryId: memoryId, recordId: recordId).map(\.version)) ?? []
  return CLIUsageError("version_not_retained: version \(version) is not retained; retained versions: [\(retained.map(String.init).joined(separator: ", "))] (dropped by retention or never a stored version)")
}
