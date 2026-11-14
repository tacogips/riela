import Foundation
import RielaCore

public enum WorkflowImprovementDigest {
  public static func build(
    session: WorkflowSession,
    excludedNodeIds: Set<String>,
    maxStepExecutions: Int,
    maxFieldChars: Int
  ) -> (digest: JSONValue, evidence: [WorkflowDefinitionEvidenceRef]) {
    let limit = max(1, maxStepExecutions)
    let fieldLimit = max(1, maxFieldChars)
    let candidates = session.executions.filter { !excludedNodeIds.contains($0.nodeId) }
    let priority = candidates.filter { $0.status == .failed || $0.attempt > 1 }
      .sorted(by: newestFirst)
    let ordinary = candidates.filter { $0.status != .failed && $0.attempt <= 1 }
      .sorted(by: newestFirst)
    let selected = Array((priority + ordinary).prefix(limit)).sorted(by: oldestFirst)
    let entries = selected.map { execution -> JSONValue in
      var truncated = false
      func bounded(_ value: String?) -> JSONValue {
        guard let value else { return .null }
        let clipped = String(value.prefix(fieldLimit))
        if clipped.count != value.count { truncated = true }
        return .string(clipped)
      }
      let input = execution.inputSnapshot.flatMap { try? JSONCanonical.encode($0) }
        .flatMap { String(data: $0, encoding: .utf8) }
      let output = execution.acceptedOutput.flatMap { try? JSONCanonical.encode($0.payload) }
        .flatMap { String(data: $0, encoding: .utf8) }
      var object: JSONObject = [
        "stepId": bounded(execution.stepId), "nodeId": bounded(execution.nodeId),
        "stepExecutionId": bounded(execution.executionId), "attempt": .integer(Int64(execution.attempt)),
        "status": bounded(execution.status.rawValue), "failureKind": bounded(execution.failureKind?.rawValue),
        "failureReason": bounded(execution.failureReason), "inputSnapshot": bounded(input ?? nil),
        "acceptedOutput": bounded(output ?? nil)
      ]
      if let usage = execution.usage, let data = try? JSONCanonical.encode(usage), let text = String(data: data, encoding: .utf8) {
        object["usage"] = bounded(text)
      } else {
        object["usage"] = .null
      }
      if truncated { object["truncated"] = .bool(true) }
      return .object(object)
    }
    let omitted = max(0, candidates.count - selected.count)
    let digest: JSONValue = .object([
      "sessionId": .string(session.sessionId), "workflowStatus": .string(session.status.rawValue),
        "stepExecutions": .array(entries), "omittedCount": .integer(Int64(omitted))
    ])
    let evidence = [WorkflowDefinitionEvidenceRef(kind: .session, id: session.sessionId)] + selected.map {
      WorkflowDefinitionEvidenceRef(kind: .stepExecution, id: $0.executionId)
    }
    return (digest, evidence)
  }

  public static func excludedNodeIds(runtimeWorkflow: WorkflowDefinition, extra: [String]) -> Set<String> {
    Set(runtimeWorkflow.nodeRegistry.compactMap { node in
      guard let addonName = node.addon?.name,
            addonName == "riela/improve-workflow-context" || addonName == "riela/improve-workflow-apply" else { return nil }
      return node.id
    }).union(extra)
  }

  public static func touchedExcludedNodes(before: JSONValue, after: JSONValue, excludedNodeIds: Set<String>) -> [String] {
    guard case let .object(beforeFiles) = before, case let .object(afterFiles) = after else { return [] }
    var touched = Set<String>()
    let beforeFootprint = excludedFootprint(files: beforeFiles, excludedNodeIds: excludedNodeIds)
    let afterFootprint = excludedFootprint(files: afterFiles, excludedNodeIds: excludedNodeIds)
    var nodeFileOwners = beforeFootprint.nodeFileOwners
    nodeFileOwners.merge(afterFootprint.nodeFileOwners, uniquingKeysWith: { $0.union($1) })
    var promptFileOwners = beforeFootprint.promptFileOwners
    promptFileOwners.merge(afterFootprint.promptFileOwners, uniquingKeysWith: { $0.union($1) })
    for path in Set(beforeFiles.keys).union(afterFiles.keys) where beforeFiles[path] != afterFiles[path] {
      if path == "workflow.json", let old = beforeFiles[path], let new = afterFiles[path] {
        collectTouchedWorkflowNodes(old, new, excludedNodeIds: excludedNodeIds, into: &touched)
      }
      touched.formUnion(nodeFileOwners[path, default: []])
      touched.formUnion(promptFileOwners[path, default: []])
    }
    return touched.sorted()
  }

  private static func excludedFootprint(files: JSONObject, excludedNodeIds: Set<String>) -> ExcludedAuthoredFootprint {
    var result = ExcludedAuthoredFootprint()
    let authoredPaths = Set(files.keys).subtracting(["workflow.json"])
    guard let workflow = files["workflow.json"]?.objectValue else { return result }

    for node in workflow["nodes"]?.arrayValue ?? [] {
      guard let row = node.objectValue, let nodeId = row["id"]?.stringValue, excludedNodeIds.contains(nodeId) else { continue }
      let nodeFile = row["nodeFile"]?.stringValue
      if let nodeFile { result.nodeFileOwners[nodeFile, default: []].insert(nodeId) }

      var promptPaths = Set<String>()
      collectAuthoredPathReferences(in: node, authoredPaths: authoredPaths, into: &promptPaths)
      if let nodeFile, let nodeFileValue = files[nodeFile] {
        collectAuthoredPathReferences(in: nodeFileValue, authoredPaths: authoredPaths, into: &promptPaths)
      }
      if let nodeFile { promptPaths.remove(nodeFile) }
      for path in promptPaths { result.promptFileOwners[path, default: []].insert(nodeId) }
    }

    return result
  }

  private static func collectAuthoredPathReferences(
    in value: JSONValue, authoredPaths: Set<String>, into paths: inout Set<String>
  ) {
    switch value {
    case let .string(string):
      if authoredPaths.contains(string) { paths.insert(string) }
    case let .array(values):
      for value in values { collectAuthoredPathReferences(in: value, authoredPaths: authoredPaths, into: &paths) }
    case let .object(values):
      for value in values.values { collectAuthoredPathReferences(in: value, authoredPaths: authoredPaths, into: &paths) }
    default:
      break
    }
  }

  private static func collectTouchedWorkflowNodes(
    _ old: JSONValue, _ new: JSONValue, excludedNodeIds: Set<String>, into touched: inout Set<String>
  ) {
    guard case let .object(oldObject) = old, case let .object(newObject) = new else { return }
    let oldNodes = rowsById(oldObject["nodes"]?.arrayValue ?? [])
    let newNodes = rowsById(newObject["nodes"]?.arrayValue ?? [])
    for nodeId in excludedNodeIds where oldNodes[nodeId] != newNodes[nodeId] { touched.insert(nodeId) }

    let oldSteps = rowsById(oldObject["steps"]?.arrayValue ?? [])
    let newSteps = rowsById(newObject["steps"]?.arrayValue ?? [])
    let oldFootprint = stepOwners(oldSteps, excludedNodeIds: excludedNodeIds)
    let newFootprint = stepOwners(newSteps, excludedNodeIds: excludedNodeIds)
    var excludedStepOwners = oldFootprint
    excludedStepOwners.merge(newFootprint, uniquingKeysWith: { $0.union($1) })

    for stepId in Set(oldSteps.keys).union(newSteps.keys) {
      let oldRows = oldSteps[stepId, default: []]
      let newRows = newSteps[stepId, default: []]
      if oldRows != newRows {
        for step in oldRows + newRows {
          if let nodeId = step.objectValue?["nodeId"]?.stringValue, excludedNodeIds.contains(nodeId) { touched.insert(nodeId) }
          if excludedNodeIds.contains(stepId) { touched.insert(stepId) }
        }
      }

      let oldTransitions = oldRows.flatMap { $0.objectValue?["transitions"]?.arrayValue ?? [] }
      let newTransitions = newRows.flatMap { $0.objectValue?["transitions"]?.arrayValue ?? [] }
      guard oldTransitions != newTransitions else { continue }
      for transition in oldTransitions + newTransitions {
        guard let targetStepId = transition.objectValue?["toStepId"]?.stringValue else { continue }
        touched.formUnion(excludedStepOwners[targetStepId, default: []])
      }
    }
  }

  private static func rowsById(_ rows: [JSONValue]) -> [String: [JSONValue]] {
    let identifiedRows = rows.compactMap { value -> (id: String, value: JSONValue)? in
      guard let row = value.objectValue, let id = row["id"]?.stringValue else { return nil }
      return (id: id, value: value)
    }
    return Dictionary(grouping: identifiedRows, by: \.id).mapValues { group in group.map(\.value) }
  }

  private static func stepOwners(_ steps: [String: [JSONValue]], excludedNodeIds: Set<String>) -> [String: Set<String>] {
    var result: [String: Set<String>] = [:]
    for (stepId, rows) in steps {
      var owners = Set<String>()
      for step in rows {
        if let nodeId = step.objectValue?["nodeId"]?.stringValue, excludedNodeIds.contains(nodeId) { owners.insert(nodeId) }
      }
      if excludedNodeIds.contains(stepId) { owners.insert(stepId) }
      if !owners.isEmpty { result[stepId] = owners }
    }
    return result
  }

  private static func newestFirst(_ lhs: WorkflowStepExecution, _ rhs: WorkflowStepExecution) -> Bool {
    lhs.createdAt == rhs.createdAt ? lhs.executionId > rhs.executionId : lhs.createdAt > rhs.createdAt
  }

  private static func oldestFirst(_ lhs: WorkflowStepExecution, _ rhs: WorkflowStepExecution) -> Bool {
    lhs.createdAt == rhs.createdAt ? lhs.executionId < rhs.executionId : lhs.createdAt < rhs.createdAt
  }
}

private struct ExcludedAuthoredFootprint {
  var nodeFileOwners: [String: Set<String>] = [:]
  var promptFileOwners: [String: Set<String>] = [:]
}

private extension Data {
  var stringValue: String? { String(data: self, encoding: .utf8) }
}

private extension JSONValue { var arrayValue: [JSONValue]? { if case let .array(value) = self { return value }; return nil } }
private extension JSONValue { var objectValue: JSONObject? { if case let .object(value) = self { return value }; return nil } }
