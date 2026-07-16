import Foundation

extension DeterministicWorkflowRunner {
  func dispatchFanout(
    directive: WorkflowFanoutDispatchDirective,
    parentSessionId: String,
    parentStepId: String,
    request: DeterministicWorkflowRunRequest
  ) async throws -> JSONObject {
    try validateFanoutWriteOwnership(directive)
    let items = try fanoutItems(from: directive)
    let fanoutGroupRunId = "\(directive.groupId):\(directive.sourceStepExecutionId)"
    if items.isEmpty {
      let join = fanoutJoinPayload(
        directive: directive,
        fanoutGroupRunId: fanoutGroupRunId,
        branches: []
      )
      try await appendFanoutJoinMessage(
        join,
        directive: directive,
        parentSessionId: parentSessionId,
        parentStepId: parentStepId
      )
      return join
    }

    let bound = fanoutConcurrencyBound(itemCount: items.count, directive: directive, request: request)
    let outcomes = await runFanoutBranches(
      items: items,
      directive: directive,
      request: request,
      concurrency: bound
    )
    let orderedBranches = outcomes.sorted { $0.index < $1.index }.map(\.record)
    let join = fanoutJoinPayload(
      directive: directive,
      fanoutGroupRunId: fanoutGroupRunId,
      branches: orderedBranches
    )
    if directive.failurePolicy == .failFast, let failed = outcomes.first(where: { $0.isFailure }) {
      throw DeterministicWorkflowRunnerError.fanoutDispatchFailed(
        groupId: directive.groupId,
        reason: "branch \(failed.index) failed: \(failed.failureReason ?? "unknown failure")"
      )
    }
    if directive.failurePolicy == .collectAll, let failed = outcomes.first(where: { $0.isFailure }) {
      throw DeterministicWorkflowRunnerError.fanoutDispatchFailed(
        groupId: directive.groupId,
        reason: "collect-all fanout recorded \(outcomes.filter(\.isFailure).count) failed branch(es); first failure at branch \(failed.index): \(failed.failureReason ?? "unknown failure")"
      )
    }
    try await appendFanoutJoinMessage(
      join,
      directive: directive,
      parentSessionId: parentSessionId,
      parentStepId: parentStepId
    )
    return join
  }

  func branchRootOutputIfStoppingBeforeStep(
    publishResult: WorkflowPublicationResult,
    request: DeterministicWorkflowRunRequest
  ) async throws -> JSONObject? {
    guard let stopBeforeStepId = request.stopBeforeStepId,
          publishResult.nextStepId == stopBeforeStepId,
          var acceptedOutput = publishResult.stepExecution.acceptedOutput else {
      return nil
    }
    acceptedOutput.isRootOutput = true
    _ = try await store.updateStepExecution(WorkflowStepExecutionUpdateInput(
      sessionId: publishResult.session.sessionId,
      executionId: publishResult.stepExecution.executionId,
      status: publishResult.stepExecution.status,
      acceptedOutput: acceptedOutput,
      adapterOutput: publishResult.stepExecution.adapterOutput,
      usage: publishResult.stepExecution.usage
    ))
    return acceptedOutput.payload
  }

  private func runFanoutBranches(
    items: [JSONValue],
    directive: WorkflowFanoutDispatchDirective,
    request: DeterministicWorkflowRunRequest,
    concurrency: Int
  ) async -> [FanoutBranchOutcome] {
    await withTaskGroup(of: FanoutBranchOutcome.self) { group in
      var nextIndex = 0
      var outcomes: [FanoutBranchOutcome] = []
      var shouldScheduleMore = true

      func scheduleNext() {
        let index = nextIndex
        nextIndex += 1
        group.addTask {
          await self.runFanoutBranch(
            index: index,
            item: items[index],
            directive: directive,
            request: request
          )
        }
      }

      for _ in 0..<min(concurrency, items.count) {
        scheduleNext()
      }
      while let outcome = await group.next() {
        outcomes.append(outcome)
        if directive.failurePolicy == .failFast, outcome.isFailure {
          shouldScheduleMore = false
          group.cancelAll()
        }
        if shouldScheduleMore, nextIndex < items.count {
          scheduleNext()
        }
      }
      return outcomes
    }
  }

  private func runFanoutBranch(
    index: Int,
    item: JSONValue,
    directive: WorkflowFanoutDispatchDirective,
    request: DeterministicWorkflowRunRequest
  ) async -> FanoutBranchOutcome {
    do {
      try Task.checkCancellation()
      var branchWorkflow = request.workflow
      var branchNodePayloads = request.nodePayloads
      if let workflowId = directive.workflowId {
        guard let calleeResolver else {
          return .failure(
            index: index,
            item: item,
            sessionId: nil,
            reason: "no callee workflow resolver is wired for cross-workflow fanout dispatch '\(workflowId)'"
          )
        }
        guard request.crossWorkflowDispatchDepth < Self.maxCrossWorkflowDispatchDepth else {
          return .failure(
            index: index,
            item: item,
            sessionId: nil,
            reason: "cross-workflow dispatch depth exceeded \(Self.maxCrossWorkflowDispatchDepth); check workflows for a call cycle"
          )
        }
        let callee = try await calleeResolver.resolveCallee(workflowId: workflowId)
        guard callee.workflow.workflowId == workflowId else {
          return .failure(
            index: index,
            item: item,
            sessionId: nil,
            reason: "resolved workflow has workflowId '\(callee.workflow.workflowId)', expected '\(workflowId)'"
          )
        }
        branchWorkflow = callee.workflow
        branchNodePayloads = callee.nodePayloads
      }
      branchWorkflow.entryStepId = directive.targetStepId
      var branchVariables = request.variables
      if let itemVariable = directive.itemVariable, !itemVariable.isEmpty {
        branchVariables[itemVariable] = item
      }
      branchVariables["fanoutItem"] = item
      branchVariables["fanoutIndex"] = .integer(Int64(index))
      branchVariables["fanoutGroupId"] = .string(directive.groupId)

      let branchRequest = DeterministicWorkflowRunRequest(
        workflow: branchWorkflow,
        nodePayloads: branchNodePayloads,
        variables: branchVariables,
        maxSteps: request.maxSteps,
        maxConcurrency: request.maxConcurrency,
        maxLoopIterations: request.maxLoopIterations,
        defaultTimeoutMs: request.defaultTimeoutMs,
        timeoutMs: request.timeoutMs,
        addonAttachments: request.addonAttachments,
        addonAttachmentDescriptors: request.addonAttachmentDescriptors,
        memoryRootDirectory: request.memoryRootDirectory,
        agentSilenceWarningMs: request.agentSilenceWarningMs,
        agentSilenceMonitorIntervalMs: request.agentSilenceMonitorIntervalMs,
        effectiveInstance: request.effectiveInstance,
        eventHandler: request.eventHandler,
        crossWorkflowDispatchDepth: directive.workflowId == nil
          ? request.crossWorkflowDispatchDepth
          : request.crossWorkflowDispatchDepth + 1,
        stopBeforeStepId: directive.joinStepId
      )
      let result = try await run(branchRequest)
      guard result.status == .completed else {
        return .failure(
          index: index,
          item: item,
          sessionId: result.session.sessionId,
          reason: "branch session ended with status '\(result.status.rawValue)'"
        )
      }
      return .success(
        index: index,
        item: item,
        output: result.rootOutput ?? [:],
        sessionId: result.session.sessionId
      )
    } catch {
      return .failure(
        index: index,
        item: item,
        sessionId: nil,
        reason: workflowRunFailureReason(error)
      )
    }
  }

  private func appendFanoutJoinMessage(
    _ fanoutJoin: JSONObject,
    directive: WorkflowFanoutDispatchDirective,
    parentSessionId: String,
    parentStepId: String
  ) async throws {
    _ = try await store.appendWorkflowMessage(WorkflowMessageAppendInput(
      workflowExecutionId: parentSessionId,
      fromStepId: parentStepId,
      toStepId: directive.joinStepId,
      routingScope: .workflow,
      deliveryKind: .direct,
      sourceStepExecutionId: directive.sourceStepExecutionId,
      transitionCondition: directive.transitionLabel,
      payload: ["fanoutJoin": .object(fanoutJoin)]
    ))
  }

  private func fanoutJoinPayload(
    directive: WorkflowFanoutDispatchDirective,
    fanoutGroupRunId: String,
    branches: [JSONObject]
  ) -> JSONObject {
    [
      "fanoutGroupRunId": .string(fanoutGroupRunId),
      "groupId": .string(directive.groupId),
      "sourceStepId": .string(directive.sourceStepId),
      "sourceStepExecutionId": .string(directive.sourceStepExecutionId),
      "targetStepId": .string(directive.targetStepId),
      "joinStepId": .string(directive.joinStepId),
      "resultOrder": .string(directive.resultOrder.rawValue),
      "failurePolicy": .string(directive.failurePolicy.rawValue),
      "branches": .array(branches.map(JSONValue.object))
    ]
  }

  private func fanoutConcurrencyBound(
    itemCount: Int,
    directive: WorkflowFanoutDispatchDirective,
    request: DeterministicWorkflowRunRequest
  ) -> Int {
    let transitionBound = directive.concurrency ?? itemCount
    let runBound = request.maxConcurrency ?? transitionBound
    return max(1, min(itemCount, transitionBound, runBound))
  }

  private func fanoutItems(from directive: WorkflowFanoutDispatchDirective) throws -> [JSONValue] {
    guard let value = jsonPointerValue(in: .object(directive.sourcePayload), pointer: directive.itemsFrom) else {
      throw DeterministicWorkflowRunnerError.fanoutDispatchFailed(
        groupId: directive.groupId,
        reason: "itemsFrom '\(directive.itemsFrom)' did not resolve in source payload"
      )
    }
    guard case let .array(items) = value else {
      throw DeterministicWorkflowRunnerError.fanoutDispatchFailed(
        groupId: directive.groupId,
        reason: "itemsFrom '\(directive.itemsFrom)' resolved to \(jsonTypeName(value)), expected array"
      )
    }
    return items
  }

  private func validateFanoutWriteOwnership(_ directive: WorkflowFanoutDispatchDirective) throws {
    guard let ownership = directive.writeOwnership else {
      return
    }
    switch ownership.mode {
    case .readOnly:
      return
    case .isolatedWorkspace:
      throw DeterministicWorkflowRunnerError.fanoutDispatchFailed(
        groupId: directive.groupId,
        reason: "fanout writeOwnership isolated-workspace is not supported by this runner"
      )
    case .disjointPaths:
      let entries = (ownership.paths ?? []) + (ownership.directories ?? [])
      let normalized = try normalizedDisjointOwnershipPaths(entries, groupId: directive.groupId)
      guard !normalized.isEmpty else {
        throw DeterministicWorkflowRunnerError.fanoutDispatchFailed(
          groupId: directive.groupId,
          reason: "fanout writeOwnership disjoint-paths requires at least one path or directory"
        )
      }
      for (offset, path) in normalized.enumerated() {
        for other in normalized.dropFirst(offset + 1) where other == path || other.hasPrefix(path + "/") {
          throw DeterministicWorkflowRunnerError.fanoutDispatchFailed(
            groupId: directive.groupId,
            reason: "fanout writeOwnership disjoint-paths contains overlapping entries '\(path)' and '\(other)'"
          )
        }
      }
    }
  }

  private func normalizedDisjointOwnershipPaths(_ entries: [String], groupId: String) throws -> [String] {
    try entries.map { entry in
      let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
      let normalized = (trimmed as NSString).standardizingPath
      guard !trimmed.isEmpty,
            !trimmed.hasPrefix("/"),
            normalized != ".",
            normalized != "..",
            !normalized.hasPrefix("../"),
            !normalized.contains("/../") else {
        throw DeterministicWorkflowRunnerError.fanoutDispatchFailed(
          groupId: groupId,
          reason: "fanout writeOwnership disjoint-paths entry '\(entry)' must be a safe relative path"
        )
      }
      return normalized
    }
    .sorted()
  }
}

private struct FanoutBranchOutcome: Sendable {
  var index: Int
  var record: JSONObject

  var isFailure: Bool {
    if case .string("completed")? = record["status"] {
      return false
    }
    return true
  }

  var failureReason: String? {
    if case let .string(reason)? = record["failureReason"] {
      return reason
    }
    return nil
  }

  static func success(index: Int, item: JSONValue, output: JSONObject, sessionId: String) -> FanoutBranchOutcome {
    FanoutBranchOutcome(index: index, record: [
      "index": .integer(Int64(index)),
      "item": item,
      "status": .string("completed"),
      "output": .object(output),
      "sessionId": .string(sessionId)
    ])
  }

  static func failure(index: Int, item: JSONValue, sessionId: String?, reason: String) -> FanoutBranchOutcome {
    var record: JSONObject = [
      "index": .integer(Int64(index)),
      "item": item,
      "status": .string(isWorkflowRunCancellationReason(reason) ? "cancelled" : "failed"),
      "failureReason": .string(reason)
    ]
    if let sessionId {
      record["sessionId"] = .string(sessionId)
    }
    return FanoutBranchOutcome(index: index, record: record)
  }
}

private func jsonPointerValue(in value: JSONValue, pointer: String) -> JSONValue? {
  guard !pointer.isEmpty else {
    return value
  }
  guard pointer.hasPrefix("/") else {
    return nil
  }
  var current = value
  for rawSegment in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
    let segment = rawSegment.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    switch current {
    case let .object(object):
      guard let next = object[segment] else {
        return nil
      }
      current = next
    case let .array(array):
      guard let index = Int(segment), array.indices.contains(index) else {
        return nil
      }
      current = array[index]
    case .null, .bool, .integer, .number, .string:
      return nil
    }
  }
  return current
}

private func jsonTypeName(_ value: JSONValue) -> String {
  switch value {
  case .null:
    return "null"
  case .bool:
    return "bool"
  case .integer, .number:
    return "number"
  case .string:
    return "string"
  case .array:
    return "array"
  case .object:
    return "object"
  }
}

private func isWorkflowRunCancellationReason(_ reason: String) -> Bool {
  reason.contains("CancellationError") || reason.lowercased().contains("cancel")
}
