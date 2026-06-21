import Foundation
import RielaMemory

public struct MemorySaveCommandResult: Codable, Equatable, Sendable {
  public var memoryId: String
  public var databasePath: String
  public var record: MemoryRecord
}

public struct MemorySearchCommandResult: Codable, Equatable, Sendable {
  public var memoryId: String
  public var databasePath: String
  public var workflowId: String?
  public var allWorkflows: Bool
  public var nodeId: String?
  public var matchPatterns: [String]
  public var limit: Int
  public var records: [MemoryRecord]
}

public struct MemoryCommandRunner: Sendable {
  public init() {}

  public func run(_ command: MemoryCommand) -> CLICommandResult {
    do {
      switch command.kind {
      case .save:
        return try save(command.options)
      case .load:
        return try list(command.options, matchPatterns: [])
      case .search:
        return try list(command.options, matchPatterns: command.options.matchPatterns)
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
      limit: options.limit,
      records: records
    )
    return try render(result, output: options.output) { result in
      result.records.map { record in
        "\(record.registeredAt) \(record.workflowId) \(record.nodeId ?? "-") #\(record.recordId) \(compactPayload(record.payload))"
      }.joined(separator: "\n") + (result.records.isEmpty ? "" : "\n")
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
    throw CLIUsageError("memory save requires --payload-json or --payload-file")
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
