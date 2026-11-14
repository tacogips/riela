import Foundation
import RielaCore
import RielaWorkflowRegistry

private struct WorkflowDefinitionUpdateJSON: Encodable {
  var accepted = true
  var outcome: WorkflowDefinitionUpdateOutcome
  var versionId: String
  var digest: String
  var auditId: String?
  var diff: [WorkflowDefinitionDiffEntry]
}

private struct WorkflowDefinitionShowJSON: Encodable {
  var head: WorkflowDefinitionHead?
  var version: WorkflowDefinitionVersion
  var document: WorkflowDefinitionDocument?
  var authored: JSONValue?
  var node: AgentNodePayload?
}

private struct WorkflowDefinitionRestoreJSON: Encodable {
  var version: WorkflowDefinitionVersion
  var audit: WorkflowDefinitionAuditRecord
}

private struct WorkflowDefinitionExportJSON: Encodable {
  var paths: [String]
}

private struct WorkflowDefinitionErrorJSON: Encodable {
  struct Detail: Encodable {
    var code: String
    var message: String
    var retainedVersionIds: [String]?
    var retainedGenerations: Int?

    init(code: String, message: String, retainedVersionIds: [String]? = nil, retainedGenerations: Int? = nil) {
      self.code = code
      self.message = message
      self.retainedVersionIds = retainedVersionIds
      self.retainedGenerations = retainedGenerations
    }
  }
  var accepted = false
  var error: Detail
}

public struct WorkflowDefinitionCommand: Sendable {
  private let resolver: any WorkflowBundleResolving

  public init() {
    resolver = FileSystemWorkflowBundleResolver()
  }

  init(resolver: any WorkflowBundleResolving) {
    self.resolver = resolver
  }

  public func run(_ options: WorkflowDefinitionCommandOptions) -> CLICommandResult {
    let parsed: ParsedWorkflowDefinitionCommand
    do {
      parsed = try ParsedWorkflowDefinitionCommand(options.arguments)
    } catch let error as WorkflowDefinitionCLIError {
      return failure(code: error.code, message: error.message, usage: error.isUsage, json: requestsJSON(options.arguments))
    } catch {
      return failure(code: "usage_error", message: String(describing: error), usage: true, json: requestsJSON(options.arguments))
    }
    do {
      return try execute(parsed)
    } catch let error as WorkflowDefinitionCLIError {
      return failure(code: error.code, message: error.message, usage: error.isUsage, json: parsed.output == .json)
    } catch let error as WorkflowDefinitionHistoryConfiguration.ConfigurationError {
      return failure(code: "invalid_configuration", message: error.description, usage: true, json: parsed.output == .json)
    } catch let error as WorkflowDefinitionServiceError {
      return failure(code: error.code.rawValue, message: error.message, usage: false, json: parsed.output == .json)
    } catch let error as WorkflowDefinitionStoreError {
      let code: String
      switch error.code {
      case .headMissing: code = "definition_not_registered"
      case .staleHead: code = "definition_conflict"
      case .missingReason: code = "reason_required"
      default: code = error.code.rawValue
      }
      if parsed.output == .json, error.code == .versionNotRetained {
        return retainedVersionFailure(error)
      }
      return failure(code: code, message: error.message, usage: false, json: parsed.output == .json)
    } catch {
      return failure(code: "definition_error", message: String(describing: error), usage: false, json: parsed.output == .json)
    }
  }

  private func execute(_ parsed: ParsedWorkflowDefinitionCommand) throws -> CLICommandResult {
    if parsed.operation == .prune, parsed.has("--all-workflows") {
      return try pruneAllWorkflows(parsed)
    }
    let root: String
    if parsed.operation == .import {
      let existing = try selectedRoot(for: parsed)
      if let existing {
        root = existing
      } else {
        let resolution = try resolution(for: parsed, directoryOption: "--workflow-definition-dir")
        let fileBundle = try resolver.resolve(resolution)
        root = WorkflowDefinitionStoreSelection.seedRoot(
          sessionStore: parsed.value("--session-store"),
          resolution: resolution,
          fileBundle: fileBundle
        )
      }
    } else {
      guard let selected = try selectedRoot(for: parsed) else {
        throw WorkflowDefinitionServiceError(
          code: .definitionNotRegistered,
          message: "workflow \(parsed.workflowName) is not registered in the definition store"
        )
      }
      root = selected
    }
    let writesHistory = [.import, .update, .updatePrompt, .restore, .undo, .redo].contains(parsed.operation)
    let defaultRetention = writesHistory ? try WorkflowDefinitionHistoryConfiguration.resolve(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
      projectDirectory: parsed.workingDirectory,
      environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
    ) : 10
    let service = WorkflowDefinitionService(storeRoot: root, fileResolver: resolver, defaultHistoryRetention: defaultRetention)
    let historyRetention = parsed.value("--history-retention").flatMap(Int.init)
    let actor = WorkflowDefinitionActor(
      kind: WorkflowDefinitionActorKind(rawValue: parsed.value("--actor-kind") ?? "cli") ?? .cli,
      id: parsed.value("--actor") ?? NSUserName()
    )
    let evidence = try parsed.all("--evidence").map(WorkflowDefinitionEvidenceRef.parse)
    switch parsed.operation {
    case .history:
      let records = try service.history(workflowName: parsed.workflowName, nodeId: parsed.value("--node"), limit: parsed.value("--limit").flatMap(Int.init))
      let dropped = records.contains { !$0.retained }
      let retainedVersions = records.filter(\.retained).count
      let retentionLine = dropped ? "older versions dropped by retention (retained: \(retainedVersions) shown)\n" : ""
      return try success(records, text: records.map(auditLine).joined(separator: "\n") + (records.isEmpty ? "" : "\n") + retentionLine, output: parsed.output)
    case .show:
      if parsed.has("--authored") {
        let authored = try service.authoredView(workflowName: parsed.workflowName, versionId: parsed.value("--version"))
        return try success(
          authored.view,
          text: "version \(authored.version.versionId) authored-files=\(authored.version.documentDigest)\n",
          output: parsed.output
        )
      }
      let shown = try service.show(workflowName: parsed.workflowName, versionId: parsed.value("--version"))
      let node = parsed.value("--node").flatMap { shown.document.runtime.nodePayloads[$0] }
      if let nodeId = parsed.value("--node"), node == nil {
        throw WorkflowDefinitionServiceError(code: .invalidDefinition, message: "node \(nodeId) was not found")
      }
      return try success(
        WorkflowDefinitionShowJSON(head: shown.head, version: shown.version, document: node == nil ? shown.document : nil, authored: nil, node: node),
        text: "version \(shown.version.versionId) digest=\(shown.version.documentDigest)\n",
        output: parsed.output
      )
    case .diff:
      let fileResolution = parsed.has("--file") ? try resolution(for: parsed) : nil
      let diff = try service.diff(
        workflowName: parsed.workflowName,
        fromVersionId: parsed.value("--from"),
        toVersionId: parsed.value("--to"),
        againstFile: fileResolution
      )
      return try success(diff, text: diffText(diff), output: parsed.output)
    case .update:
      let reason = parsed.value("--reason") ?? ""
      let result: WorkflowDefinitionUpdateResult
      if let patchPath = parsed.value("--patch") {
        let patch: JSONValue
        do {
          let data = try Data(contentsOf: absoluteURL(patchPath, workingDirectory: parsed.workingDirectory))
          patch = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
          throw WorkflowDefinitionCLIError(code: "invalid_patch", message: "could not read or decode patch: \(error)", isUsage: false)
        }
        result = try service.update(
          workflowName: parsed.workflowName,
          source: .patch(patch),
          reason: reason,
          expectedVersionId: parsed.value("--expected-version"),
          evidence: evidence,
          actor: actor,
          historyRetention: historyRetention
        )
      } else {
        let resolution = try resolution(for: parsed, directoryOption: "--from-file")
        if parsed.has("--force") {
          let imported = try service.importDefinition(resolution: resolution, force: true, reason: reason, evidence: evidence, actor: actor, historyRetention: historyRetention)
          return try success(imported, text: "\(imported.outcome.rawValue) version=\(imported.version?.versionId ?? "")\n", output: parsed.output)
        }
        result = try service.update(
          workflowName: parsed.workflowName,
          source: .fromDirectory(resolution),
          reason: reason,
          expectedVersionId: parsed.value("--expected-version"),
          evidence: evidence,
          actor: actor,
          historyRetention: historyRetention
        )
      }
      let json = WorkflowDefinitionUpdateJSON(
        outcome: result.outcome,
        versionId: result.versionId,
        digest: result.digest,
        auditId: result.audit?.auditId,
        diff: result.diff
      )
      return try success(json, text: "\(result.outcome.rawValue) version=\(result.versionId) digest=\(result.digest)\n", output: parsed.output)
    case .updatePrompt:
      let promptText: String
      if let text = parsed.value("--text") {
        promptText = text
      } else if let textFile = parsed.value("--text-file") {
        promptText = try String(contentsOf: absoluteURL(textFile, workingDirectory: parsed.workingDirectory), encoding: .utf8)
      } else {
        throw WorkflowDefinitionCLIError.usage("update-prompt requires --text or --text-file")
      }
      let field = try WorkflowDefinitionPromptField(parsing: parsed.value("--field") ?? "")
      let result = try service.updatePrompt(
        workflowName: parsed.workflowName,
        nodeId: parsed.value("--node") ?? "",
        field: field,
        text: promptText,
        reason: parsed.value("--reason") ?? "",
        expectedVersionId: parsed.value("--expected-version"),
        evidence: evidence,
        actor: actor,
        historyRetention: historyRetention
      )
      return try success(
        WorkflowDefinitionRestoreJSON(version: result.0, audit: result.1),
        text: "updated version=\(result.0.versionId) audit=\(result.1.auditId)\n",
        output: parsed.output
      )
    case .restore:
      let result = try service.restore(
        workflowName: parsed.workflowName,
        versionId: parsed.value("--version") ?? "",
        reason: parsed.value("--reason") ?? "",
        evidence: evidence,
        actor: actor,
        historyRetention: historyRetention
      )
      return try success(WorkflowDefinitionRestoreJSON(version: result.0, audit: result.1), text: "restored version=\(result.0.versionId)\n", output: parsed.output)
    case .undo, .redo:
      let expectedVersion = parsed.value("--expected-version")
      let expectedRevision = parsed.value("--expected-revision").flatMap(Int64.init)
      let result = try parsed.operation == .undo
        ? service.undo(workflowName: parsed.workflowName, reason: parsed.value("--reason") ?? "", evidence: evidence,
                       actor: actor, expectedRevision: expectedRevision, expectedVersionId: expectedVersion)
        : service.redo(workflowName: parsed.workflowName, reason: parsed.value("--reason") ?? "", evidence: evidence,
                       actor: actor, expectedRevision: expectedRevision, expectedVersionId: expectedVersion)
      return try success(WorkflowDefinitionRestoreJSON(version: result.version, audit: result.audit),
                         text: "\(parsed.operation.rawValue) version=\(result.version.versionId)\n", output: parsed.output)
    case .import:
      let resolution = try resolution(for: parsed, directoryOption: "--workflow-definition-dir")
      let imported = try service.importDefinition(
        resolution: resolution,
        force: parsed.has("--force"),
        reason: parsed.value("--reason"),
        evidence: evidence,
        actor: actor,
        historyRetention: historyRetention
      )
      return try success(imported, text: "\(imported.outcome.rawValue)\(imported.version.map { " version=\($0.versionId)" } ?? "")\n\(diffText(imported.diff))", output: parsed.output)
    case .export:
      let target: WorkflowDefinitionExportTarget = parsed.has("--to-source")
        ? .source(overwrite: parsed.has("--overwrite"))
        : .directory(absoluteURL(parsed.value("--to") ?? "", workingDirectory: parsed.workingDirectory).path)
      let files = try service.export(workflowName: parsed.workflowName, versionId: parsed.value("--version"), target: target)
      return try success(WorkflowDefinitionExportJSON(paths: files.map(\.path)), text: files.map(\.path).joined(separator: "\n") + (files.isEmpty ? "" : "\n"), output: parsed.output)
    case .prune:
      let result = try service.prune(
        workflowName: parsed.workflowName,
        keepVersions: parsed.value("--keep").flatMap(Int.init) ?? 0,
        reason: parsed.value("--reason") ?? "",
        actor: actor,
        dryRun: parsed.has("--dry-run")
      )
      return try success(result, text: retentionLine(result) + "\n", output: parsed.output)
    case .purgeHistory:
      let result = try service.purgeHistory(
        workflowName: parsed.workflowName,
        reason: parsed.value("--reason") ?? "",
        actor: actor,
        dryRun: parsed.has("--dry-run")
      )
      return try success(result, text: retentionLine(result) + "\n", output: parsed.output)
    }
  }

  /// Prunes every registered workflow in each candidate store that exists.
  private func pruneAllWorkflows(_ parsed: ParsedWorkflowDefinitionCommand) throws -> CLICommandResult {
    let actor = WorkflowDefinitionActor(kind: .cli, id: parsed.value("--actor") ?? NSUserName())
    var results: [WorkflowDefinitionRetentionResult] = []
    for root in WorkflowDefinitionStoreSelection.candidateRoots(
      sessionStore: parsed.value("--session-store"),
      scope: parsed.scope,
      workingDirectory: parsed.workingDirectory
    ) where FileManager.default.fileExists(atPath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root)) {
      let store = WorkflowDefinitionStore(rootDirectory: root)
      for workflowName in try store.workflowNames() {
        results.append(try store.prune(
          workflowName: workflowName,
          keepVersions: parsed.value("--keep").flatMap(Int.init) ?? 0,
          reason: parsed.value("--reason") ?? "",
          actor: actor,
          dryRun: parsed.has("--dry-run")
        ))
      }
    }
    let text = results.map(retentionLine).joined(separator: "\n") + (results.isEmpty ? "" : "\n")
    return try success(results, text: text, output: parsed.output)
  }

  private func selectedRoot(for parsed: ParsedWorkflowDefinitionCommand) throws -> String? {
    try WorkflowDefinitionStoreSelection.rootWithHead(
      workflowName: parsed.workflowName,
      sessionStore: parsed.value("--session-store"),
      scope: parsed.scope,
      workingDirectory: parsed.workingDirectory
    )
  }

  private func resolution(
    for parsed: ParsedWorkflowDefinitionCommand,
    directoryOption: String? = nil
  ) throws -> WorkflowResolutionOptions {
    var directory = parsed.value(directoryOption ?? "")
    if let path = directory {
      let url = absoluteURL(path, workingDirectory: parsed.workingDirectory)
      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      if exists && !isDirectory.boolValue {
        guard url.lastPathComponent == "workflow.json" else {
          throw WorkflowDefinitionCLIError(code: "invalid_patch", message: "--from-file path must be a directory or workflow.json", isUsage: false)
        }
        directory = url.deletingLastPathComponent().path
      } else {
        directory = url.path
      }
      if directoryOption == "--from-file" {
        let child = URL(fileURLWithPath: directory!, isDirectory: true).appendingPathComponent(parsed.workflowName).appendingPathComponent("workflow.json")
        if FileManager.default.fileExists(atPath: child.path) {
          throw WorkflowDefinitionCLIError(code: "invalid_patch", message: "ambiguous --from-file directory", isUsage: false)
        }
      }
    }
    return WorkflowResolutionOptions(
      workflowName: parsed.workflowName,
      scope: directory == nil ? parsed.scope : .direct,
      workflowDefinitionDir: directory,
      workingDirectory: parsed.workingDirectory
    )
  }

  private func success<T: Encodable>(_ value: T, text: String, output: WorkflowOutputFormat) throws -> CLICommandResult {
    guard output == .json else { return CLICommandResult(exitCode: .success, stdout: text) }
    return CLICommandResult(exitCode: .success, stdout: try encode(value) + "\n")
  }

  private func failure(code: String, message: String, usage: Bool, json: Bool) -> CLICommandResult {
    if json, let output = try? encode(WorkflowDefinitionErrorJSON(error: .init(code: code, message: message))) {
      return CLICommandResult(exitCode: usage ? .usage : .failure, stdout: output + "\n")
    }
    return CLICommandResult(exitCode: usage ? .usage : .failure, stderr: message + "\n")
  }

  private func retainedVersionFailure(_ error: WorkflowDefinitionStoreError) -> CLICommandResult {
    let envelope = WorkflowDefinitionErrorJSON(error: .init(code: error.code.rawValue, message: error.message,
      retainedVersionIds: error.retainedVersionIds, retainedGenerations: error.retainedGenerations))
    return CLICommandResult(exitCode: .failure, stdout: (try? encode(envelope)).map { $0 + "\n" } ?? "")
  }

  private func encode<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
      throw WorkflowDefinitionCLIError(code: "definition_error", message: "could not encode JSON as UTF-8", isUsage: false)
    }
    return json
  }

  private func requestsJSON(_ arguments: [String]) -> Bool {
    arguments.contains { $0 == "json" } && arguments.contains("--output")
  }

  private func absoluteURL(_ path: String, workingDirectory: String) -> URL {
    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true)).standardizedFileURL
  }

  private func auditLine(_ record: WorkflowDefinitionAuditRecord) -> String {
    "\(record.createdAt) \(record.operation.rawValue) \(record.versionId) \(record.actor.kind.rawValue):\(record.actor.id ?? "") " +
      "node=\(record.targetNodeId ?? "") field=\(record.targetField ?? "") retained=\(record.retained) reason=\(record.reason)"
  }

  private func retentionLine(_ result: WorkflowDefinitionRetentionResult) -> String {
    let verb = result.dryRun ? "would remove" : "removed"
    return "\(result.mode.rawValue) \(result.workflowName): \(verb) versions=\(result.removedVersionIds.count) "
      + "audits=\(result.removedAuditCount) blobs=\(result.removedBlobCount) bytes=\(result.removedBlobBytes) "
      + "kept=\(result.keptVersionIds.count) protected=\(result.protectedVersions.map { "\($0.versionId):\($0.reason)" }.joined(separator: ","))"
  }

  private func diffText(_ diff: [WorkflowDefinitionDiffEntry]) -> String {
    diff.map { entry in
      let before = entry.before.map(compactJSON) ?? "<absent>"
      let after = entry.after.map(compactJSON) ?? "<absent>"
      return "\(entry.op.rawValue) \(entry.path)\nbefore: \(before)\nafter: \(after)"
    }.joined(separator: "\n") + (diff.isEmpty ? "" : "\n")
  }

  private func compactJSON(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "null" }
    return text
  }
}
