import Foundation
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
        return try list(command.options, matchPatterns: [])
      case .search:
        return try list(command.options, matchPatterns: command.options.matchPatterns)
      case .metadata:
        return try metadata(command.options)
      case .tags:
        return try tags(command.options)
      case .relatedIds:
        return try relatedIds(command.options)
      }
    } catch let error as CLIUsageError {
      return failure(error.message, output: command.options.output, options: command.options.cliOptions)
    } catch {
      return failure("\(error)", output: command.options.output, options: command.options.cliOptions)
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
      payload: payload
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
      payload: payload
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

  private func list(_ options: MemoryCommandOptions, matchPatterns: [String]) throws -> CLICommandResult {
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
        limit: options.limit
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
