import ArgumentParser
import Foundation
import RielaMemory

struct ParsedMemoryOptions: ParsableArguments {
  @Option var workflowId: String?
  @Flag var allWorkflows = false
  @Option var nodeId: String?
  @Option var recordId: Int64?
  @Option var version: Int64?
  @Option(name: .customLong("diff-against")) var diffAgainst: String?
  @Option var beforeVersion: Int64?
  @Option var expectedHeadVersion: Int64?
  @Option var throughVersion: Int64?
  @Option(name: .customLong("history-retention")) var historyRetention: Int?
  @Flag var dryRun = false
  @Option var payloadJSON: String?
  @Option var payloadFile: String?
  @Option var registeredAt: String?
  @Option(name: [.customLong("match"), .customShort("e")]) var matchPatterns: [String] = []
  @Option(name: .customLong("tag")) var tags: [String] = []
  @Option(name: [.customLong("related-id"), .customLong("related-record-id")])
  var relatedRecordIds: [Int64] = []
  @Option(name: [.customLong("file"), .customLong("file-path")]) var filePaths: [String] = []
  @Flag var clearFiles = false
  @Option var sort = MemoryValueSortOrder.valueAsc
  @Option var limit = 30
  @Option var maxPayloadBytes = MemorySearchOptions.defaultMaxPayloadBytes
  @Option var offset = 0
  @Option(name: [.customLong("database-root"), .customLong("memory-root")]) var databaseRoot: String?
  @Option(name: [.customLong("working-dir"), .customLong("working-directory")])
  var workingDirectory = FileManager.default.currentDirectoryPath
  @Option var output = WorkflowOutputFormat.jsonl

  init() {}

  init(_ tokens: [String]) throws {
    do {
      self = try Self.parse(tokens)
      try validateValues()
    } catch let error as CLIUsageError {
      throw error
    } catch {
      throw CLIUsageError(Self.message(for: error))
    }
  }

  func commandOptions(memoryId: String) -> MemoryCommandOptions {
    MemoryCommandOptions(
      memoryId: memoryId,
      workflowId: workflowId,
      allWorkflows: allWorkflows,
      nodeId: nodeId,
      recordId: recordId,
      version: version,
      diffAgainst: diffAgainst,
      beforeVersion: beforeVersion,
      expectedHeadVersion: expectedHeadVersion,
      throughVersion: throughVersion,
      historyRetention: historyRetention,
      dryRun: dryRun,
      payloadJSON: payloadJSON,
      payloadFile: payloadFile,
      registeredAt: registeredAt,
      matchPatterns: matchPatterns,
      tags: tags,
      relatedRecordIds: relatedRecordIds,
      filePaths: filePaths,
      clearFiles: clearFiles,
      sortOrder: sort,
      limit: limit,
      maxPayloadBytes: maxPayloadBytes,
      offset: offset,
      databaseRoot: databaseRoot,
      workingDirectory: workingDirectory,
      output: output
    )
  }

  private func validateValues() throws {
    for value in [version, beforeVersion, expectedHeadVersion, throughVersion].compactMap({ $0 }) where value <= 0 {
      throw CLIUsageError("history version options must be positive integers")
    }
    if let historyRetention, !(1...1_000).contains(historyRetention) {
      throw CLIUsageError("--history-retention must be an integer in 1...1000")
    }
    if let diffAgainst, diffAgainst != "head", Int64(diffAgainst).map({ $0 > 0 }) != true {
      throw CLIUsageError("--diff-against must be a positive version or 'head'")
    }
    if let recordId, recordId <= 0 {
      throw CLIUsageError("--record-id must be a positive integer")
    }
    if relatedRecordIds.contains(where: { $0 <= 0 }) {
      throw CLIUsageError("--related-id must be a positive integer")
    }
    guard (1...67_108_864).contains(maxPayloadBytes) else {
      throw CLIUsageError("--max-payload-bytes must be an integer in 1...67108864")
    }
    if limit <= 0 {
      throw CLIUsageError("--limit must be a positive integer")
    }
    if offset < 0 {
      throw CLIUsageError("--offset must be zero or a positive integer")
    }
    if output == .table {
      throw CLIUsageError(
        "`--output table` is only supported for workflow list, workflow status, session list, session latest, package search, package list, node search, node list, note list, note search, and note notebook list"
      )
    }
  }

  func validateCommandOptions(for kind: MemoryCommandKind) throws {
    if diffAgainst != nil, kind != .showVersion {
      throw CLIUsageError("--diff-against is only supported by memory show-version")
    }
    if historyRetention != nil, ![.save, .update, .restoreVersion].contains(kind) {
      throw CLIUsageError("--history-retention is only supported by memory save, update, and restore-version")
    }
  }
}

extension MemoryValueSortOrder: @retroactive ExpressibleByArgument {}
