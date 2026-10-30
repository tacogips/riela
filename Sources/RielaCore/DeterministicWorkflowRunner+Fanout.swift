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
    let joinContext = try fanoutContext(from: directive)
    let wave = try WorkflowFanoutWave.select(items: items, policy: directive.dependencies, source: directive.sourcePayload)
    let fanoutGroupRunId = "\(directive.groupId):\(directive.sourceStepExecutionId)"
    if wave.selectedIndices.isEmpty {
      var join = fanoutJoinPayload(
        directive: directive,
        fanoutGroupRunId: fanoutGroupRunId,
        branches: []
      )
      if let joinContext { join["context"] = joinContext }
      join["pendingBranchIds"] = .array(wave.pendingBranchIds.map(JSONValue.string))
      join["completedBranchIds"] = .array(wave.completedBranchIds.map(JSONValue.string))
      join["dispatchedBranchIds"] = .array([])
      join["allBranchesCompleted"] = .bool(true)
      try await appendFanoutJoinMessage(
        join,
        directive: directive,
        parentSessionId: parentSessionId,
        parentStepId: parentStepId
      )
      return join
    }

    // The evidence directory is created only once a branch will actually run,
    // so a no-op dispatch (nothing selectable in this wave) leaves no empty
    // evidence tree behind in the workspace.
    let changeEvidence: WorkflowFanoutChangeEvidence?
    if let tracking = directive.changeTracking {
      guard let fanoutWorkspaceRoot else {
        throw AdapterExecutionError(.policyBlocked, "fanout changeTracking requires a host-bound fanoutWorkspaceRoot")
      }
      // Preflight every selected branch before any writer starts so a
      // selection that already violates policy fails here, naming the branch.
      // Every dispatch-time failure surfaces as the group-scoped error like
      // the other dispatch failures, never as a raw adapter error.
      do {
        let evidence = try WorkflowFanoutChangeEvidence(root: fanoutWorkspaceRoot)
        for index in wave.selectedIndices {
          let selection = try fanoutTrackedSelection(item: items[index], tracking: tracking)
          _ = try await evidence.capture(
            branchId: wave.branchIds[index], paths: selection.paths,
            artifactRoots: selection.artifactRoots, stepId: "fanout-dispatch"
          )
        }
        changeEvidence = evidence
      } catch {
        if isWorkflowRunCancellation(error) {
          throw error
        }
        throw DeterministicWorkflowRunnerError.fanoutDispatchFailed(
          groupId: directive.groupId,
          reason: "fanout dispatch preflight failed: \(workflowRunFailureReason(error))"
        )
      }
    } else {
      changeEvidence = nil
    }
    let bound = fanoutConcurrencyBound(itemCount: wave.selectedIndices.count, directive: directive, request: request)
    let outcomes = try await runFanoutBranches(
      items: items,
      directive: directive,
      request: request,
      concurrency: bound,
      indices: wave.selectedIndices,
      changeEvidence: changeEvidence,
      parentSessionId: parentSessionId
    )
    // Drain siblings before stopping. A resumable child is neither a failed
    // item nor permission to cancel another child's in-flight operation.
    if let pending = outcomes.sorted(by: { $0.index < $1.index }).first(where: { $0.resumeError != nil }),
       let error = pending.resumeError {
      throw error
    }
    let orderedBranches = outcomes.sorted { $0.index < $1.index }.map { outcome in
      var record = outcome.record
      record["branchId"] = .string(wave.branchIds[outcome.index])
      return record
    }
    if let stepIds = directive.includeStepOutputs {
      var total = 0
      for branch in orderedBranches {
        guard case let .integer(index)? = branch["index"],
              case let .object(outputs)? = branch["stepOutputs"] else { continue }
        for stepId in stepIds {
          guard let value = outputs[stepId] else { continue }
          total += try JSONEncoder().encode(value).count
          if total > 8_000_000 {
            throw DeterministicWorkflowRunnerError.fanoutDispatchFailed(
              groupId: directive.groupId,
              reason: "includeStepOutputs exceeded 8000000 bytes at branch \(index) step '\(stepId)'"
            )
          }
        }
      }
    }
    var join = fanoutJoinPayload(
      directive: directive,
      fanoutGroupRunId: fanoutGroupRunId,
      branches: orderedBranches
    )
    if let joinContext { join["context"] = joinContext }
    join["pendingBranchIds"] = .array(wave.pendingBranchIds.map(JSONValue.string))
    join["completedBranchIds"] = .array(wave.completedBranchIds.map(JSONValue.string))
    join["dispatchedBranchIds"] = .array(wave.selectedIndices.map { .string(wave.branchIds[$0]) })
    join["allBranchesCompleted"] = .bool(!outcomes.contains { $0.isFailure })
    var reduceFailureReason: String?
    if let changeEvidence {
      // Reduce never discards sibling results: a root that can no longer be
      // snapshotted within policy is reported under changeEvidence.reduceFailures
      // with branch/node/phase/root/path/observed/limit, and `complete` is false.
      let changeEvidenceJoin = try await changeEvidence.reduce(
        observationInlineLimit: directive.changeTracking?.observationInlineLimit
          ?? WorkflowFanoutChangeTracking.defaultObservationInlineLimit
      )
      join["changeEvidence"] = .object(changeEvidenceJoin)
      if case let .array(failures)? = changeEvidenceJoin["reduceFailures"], let first = failures.first {
        reduceFailureReason = fanoutReduceFailureDescription(first, count: failures.count)
      }
    }
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
    if directive.failurePolicy != .collectPartial, let reduceFailureReason {
      throw DeterministicWorkflowRunnerError.fanoutDispatchFailed(
        groupId: directive.groupId,
        reason: "fanout change evidence reduction failed: \(reduceFailureReason)"
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
    concurrency: Int,
    indices: [Int],
    changeEvidence: WorkflowFanoutChangeEvidence?,
    parentSessionId: String
  ) async throws -> [FanoutBranchOutcome] {
    try await withThrowingTaskGroup(of: FanoutBranchOutcome.self) { group in
      var nextIndex = 0
      var outcomes: [FanoutBranchOutcome] = []
      var shouldScheduleMore = true

      func scheduleNext() {
        let index = indices[nextIndex]
        nextIndex += 1
        group.addTask {
          try await self.runFanoutBranch(
            index: index,
            item: items[index],
            directive: directive,
            request: request,
            changeEvidence: changeEvidence,
            parentSessionId: parentSessionId
          )
        }
      }

      for _ in 0..<min(concurrency, indices.count) {
        scheduleNext()
      }
      while let outcome = try await group.next() {
        outcomes.append(outcome)
        if directive.failurePolicy == .failFast, outcome.isFailure {
          shouldScheduleMore = false
          group.cancelAll()
        }
        if shouldScheduleMore, nextIndex < indices.count {
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
    request: DeterministicWorkflowRunRequest,
    changeEvidence: WorkflowFanoutChangeEvidence?,
    parentSessionId: String
  ) async throws -> FanoutBranchOutcome {
    var reservedChildSessionId: String?
    do {
      try Task.checkCancellation()
      var branchWorkflow = request.workflow
      var branchNodePayloads = request.nodePayloads
      var branchDefinitionSource = request.definitionSource
      if let workflowId = directive.workflowId {
        guard let calleeResolver else {
          return .failure(
            index: index,
            item: item,
            sessionId: nil,
            reason: "no callee workflow resolver is wired for cross-workflow fanout dispatch '\(workflowId)'",
            cancelled: false
          )
        }
        guard request.crossWorkflowDispatchDepth < Self.maxCrossWorkflowDispatchDepth else {
          return .failure(
            index: index,
            item: item,
            sessionId: nil,
            reason: "cross-workflow dispatch depth exceeded \(Self.maxCrossWorkflowDispatchDepth); check workflows for a call cycle",
            cancelled: false
          )
        }
        let callee = try await calleeResolver.resolveCallee(workflowId: workflowId)
        guard callee.workflow.workflowId == workflowId else {
          return .failure(
            index: index,
            item: item,
            sessionId: nil,
            reason: "resolved workflow has workflowId '\(callee.workflow.workflowId)', expected '\(workflowId)'",
            cancelled: false
          )
        }
        branchWorkflow = callee.workflow
        branchNodePayloads = callee.nodePayloads
        branchDefinitionSource = callee.definitionSource
      }
      branchWorkflow.entryStepId = directive.targetStepId
      var branchVariables = request.variables
      if let itemVariable = directive.itemVariable, !itemVariable.isEmpty {
        branchVariables[itemVariable] = item
      }
      branchVariables["fanoutItem"] = item
      branchVariables["fanoutIndex"] = .integer(Int64(index))
      branchVariables["fanoutGroupId"] = .string(directive.groupId)
      let branchId: String
      if let dependencies = directive.dependencies,
         case let .string(id)? = fanoutJSONPointer(item, dependencies.branchIdFrom) {
        branchId = id
      } else {
        branchId = String(index)
      }
      branchVariables["fanoutBranchId"] = .string(branchId)

      var branchRequest = DeterministicWorkflowRunRequest(
        workflow: branchWorkflow,
        nodePayloads: branchNodePayloads,
        variables: branchVariables,
        maxSteps: request.maxSteps,
        maxConcurrency: request.maxConcurrency,
        maxLoopIterations: request.maxLoopIterations,
        disableDefaultLoopGuard: request.disableDefaultLoopGuard,
        defaultTimeoutMs: request.defaultTimeoutMs,
        timeoutMs: request.timeoutMs,
        addonAttachments: request.addonAttachments,
        addonAttachmentDescriptors: request.addonAttachmentDescriptors,
        memoryRootDirectory: request.memoryRootDirectory,
        agentSilenceWarningMs: request.agentSilenceWarningMs,
        agentSilenceMonitorIntervalMs: request.agentSilenceMonitorIntervalMs,
        effectiveInstance: request.effectiveInstance,
        eventHandler: request.eventHandler,
        sessionExecutionAdmission: request.sessionExecutionAdmission,
        crossWorkflowDispatchDepth: directive.workflowId == nil
          ? request.crossWorkflowDispatchDepth
          : request.crossWorkflowDispatchDepth + 1,
        // Local branches stop before their caller's join. A cross-workflow
        // callee owns its complete graph, including identically named steps.
        stopBeforeStepId: directive.workflowId == nil ? directive.joinStepId : nil,
        definitionSource: branchDefinitionSource
      )
      branchRequest.workflowRunId = request.workflowRunId
      branchRequest.parentSessionId = parentSessionId
      branchRequest.rootSessionId = request.rootSessionId ?? parentSessionId
      branchRequest.resumeSessionId = try await reserveNestedSession(
        workflow: branchWorkflow,
        nodePayloads: branchNodePayloads,
        entryStepId: directive.targetStepId,
        parentSessionId: parentSessionId,
        rootSessionId: request.rootSessionId ?? parentSessionId,
        parentStepId: directive.sourceStepId,
        resumeStepId: directive.joinStepId,
        sourceExecutionId: directive.sourceStepExecutionId,
        branchId: "fanout-\(branchId)",
        definitionSource: branchDefinitionSource
      )
      reservedChildSessionId = branchRequest.resumeSessionId
      if let changeEvidence, let tracking = directive.changeTracking {
        let selection = try fanoutTrackedSelection(item: item, tracking: tracking)
        branchRequest.fanoutChangeContext = WorkflowFanoutChangeContext(
          evidence: changeEvidence, branchId: branchId, paths: selection.paths, artifactRoots: selection.artifactRoots
        )
      }
      // Keep fanout children on the same recoverable lifecycle boundaries as
      // direct cross-workflow children. These checkpoints deliberately wrap
      // the real branch runner rather than a store-only test helper.
      try await nestedInvocationRecoveryCheckpointer?.reached(.beforeChildNodeEffect)
      let result = try await run(branchRequest)
      if !result.session.status.isTerminal || result.session.failureKind == .maxStepsExceeded {
        try Task.checkCancellation()
        return try await pendingFanoutBranch(index: index, item: item, session: result.session,
          directive: directive, request: request)
      }
      if try await persistNestedTerminalIfNeeded(
        parentSessionId: parentSessionId,
        sourceExecutionId: directive.sourceStepExecutionId,
        branchId: "fanout-\(branchId)",
        terminalSession: result.session
      ) {
        try await nestedInvocationRecoveryCheckpointer?.reached(.childTerminalPersisted)
      }
      try await nestedInvocationRecoveryCheckpointer?.reached(.afterChildNodeResult)
      guard result.status == .completed else {
        return .failure(
          index: index,
          item: item,
          sessionId: result.session.sessionId,
          reason: "branch session ended with status '\(result.status.rawValue)'",
          cancelled: result.session.failureKind == .cancelled,
          stepOutputs: directive.includeStepOutputs.map { fanoutStepOutputs($0, session: result.session) }
        )
      }
      return .success(
        index: index,
        item: item,
        output: result.rootOutput ?? [:],
        sessionId: result.session.sessionId,
        stepOutputs: directive.includeStepOutputs.map { fanoutStepOutputs($0, session: result.session) }
      )
    } catch {
      if error is NestedRecoveryInterruption {
        throw error
      }
      if reservedChildSessionId == nil, isWorkflowRunCancellation(error) { throw error }
      // A collect-partial parent may publish its join only after every
      // reserved child has a canonical terminal snapshot. `run` can throw
      // after it marks a child failed, so persist that actual terminal record
      // before returning a branch failure rather than losing it in the catch.
      var terminalFailureKind: WorkflowSessionFailureKind?
      var terminalStepOutputs: JSONObject?
      if let reservedChildSessionId,
         let terminal = try await store.loadSession(id: reservedChildSessionId) {
        if !terminal.status.isTerminal || terminal.failureKind == .maxStepsExceeded {
          if isWorkflowRunCancellation(error) { throw error }
          return try await pendingFanoutBranch(index: index, item: item, session: terminal,
            directive: directive, request: request)
        }
        terminalFailureKind = terminal.failureKind
        // Read from the durable terminal snapshot so a resumed join rebuilds
        // the same accepted outputs that preceded the failure.
        terminalStepOutputs = directive.includeStepOutputs.map { fanoutStepOutputs($0, session: terminal) }
        // Workflow cancellation is represented by a failed terminal session
        // with failureKind=.cancelled. Keep that distinction in the persisted
        // snapshot: the parent join may render a cancelled branch, but must
        // never return before its canonical child terminal is durable.
        if try await persistNestedTerminalIfNeeded(
          parentSessionId: parentSessionId,
          sourceExecutionId: directive.sourceStepExecutionId,
          branchId: "fanout-\(branchIdForOutcome(item: item, index: index, directive: directive))",
          terminalSession: terminal
        ) {
          try await nestedInvocationRecoveryCheckpointer?.reached(.childTerminalPersisted)
        }
      }
      // Cancellation is decided by the real signal (the thrown cancellation
      // or the child's durable failureKind), never by scanning the failure
      // text: a policy failure naming src/CancelButton.tsx is a failure.
      return .failure(
        index: index,
        item: item,
        sessionId: reservedChildSessionId,
        reason: workflowRunFailureReason(error),
        cancelled: isWorkflowRunCancellation(error) || terminalFailureKind == .cancelled,
        stepOutputs: terminalStepOutputs
      )
    }
  }

  private func pendingFanoutBranch(
    index: Int, item: JSONValue, session: WorkflowSession,
    directive: WorkflowFanoutDispatchDirective, request: DeterministicWorkflowRunRequest
  ) async throws -> FanoutBranchOutcome {
    // Save resumable progress without sealing the immutable terminal receipt.
    // Reopening must use this same reservation and continue accepted steps.
    if let nestedInvocationPersistenceStore {
      let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
      try nestedInvocationPersistenceStore.save(.init(session: session, workflowMessages: messages))
    }
    let error: DeterministicWorkflowRunnerError
    if session.failureKind == .maxStepsExceeded {
      error = .maxStepsExceeded(session.effectiveStepBudget ?? request.effectiveStepBudget
        ?? request.maxSteps ?? max(1, request.workflow.steps.count + request.workflow.defaults.maxLoopIterations))
    } else {
      error = .fanoutDispatchPending(groupId: directive.groupId, sessionId: session.sessionId, status: session.status)
    }
    return FanoutBranchOutcome(index: index, record: [:], resumeError: error)
  }

  /// Resolves one item's tracking selection. `pathsFrom` must resolve to an
  /// array of source paths. `artifactRootsFrom` is optional per item: an
  /// absent pointer means no artifact classification (the restrictive default),
  /// while a present value must be an array of strings.
  private func fanoutTrackedSelection(
    item: JSONValue, tracking: WorkflowFanoutChangeTracking
  ) throws -> (paths: [String], artifactRoots: [String]) {
    guard case let .array(values)? = fanoutJSONPointer(item, tracking.pathsFrom) else {
      throw AdapterExecutionError(.invalidOutput, "fanout changeTracking.pathsFrom must resolve to an array")
    }
    let paths = try values.map { value -> String in
      guard case let .string(path) = value else {
        throw AdapterExecutionError(.invalidOutput, "fanout changeTracking paths must be strings")
      }
      return path
    }
    var artifactRoots: [String] = []
    if let pointer = tracking.artifactRootsFrom, let resolved = fanoutJSONPointer(item, pointer), resolved != .null {
      guard case let .array(artifactValues) = resolved else {
        throw AdapterExecutionError(.invalidOutput, "fanout changeTracking.artifactRootsFrom must resolve to an array")
      }
      artifactRoots = try artifactValues.map { value -> String in
        guard case let .string(path) = value else {
          throw AdapterExecutionError(.invalidOutput, "fanout changeTracking artifact roots must be strings")
        }
        return path
      }
    }
    return (paths, artifactRoots)
  }

  private func fanoutReduceFailureDescription(_ failure: JSONValue, count: Int) -> String {
    guard case let .object(diagnostic) = failure else { return "\(count) reduce failure(s)" }
    var parts: [String] = []
    if case let .string(reason)? = diagnostic["reason"] { parts.append(reason) }
    var fields: [String] = []
    for key in ["branchId", "node", "phase", "selection", "root", "path", "observed", "limit"] {
      switch diagnostic[key] {
      case let .string(value)?: fields.append("\(key == "branchId" ? "branch" : key)=\(value)")
      case let .integer(value)?: fields.append("\(key)=\(value)")
      default: continue
      }
    }
    if !fields.isEmpty { parts.append("[\(fields.joined(separator: " "))]") }
    if count > 1 { parts.append("(+\(count - 1) more)") }
    return parts.joined(separator: " ")
  }

  private func branchIdForOutcome(
    item: JSONValue, index: Int, directive: WorkflowFanoutDispatchDirective
  ) -> String {
    if let dependencies = directive.dependencies,
       case let .string(id)? = fanoutJSONPointer(item, dependencies.branchIdFrom) {
      return id
    }
    return String(index)
  }

  private func appendFanoutJoinMessage(
    _ fanoutJoin: JSONObject,
    directive: WorkflowFanoutDispatchDirective,
    parentSessionId: String,
    parentStepId: String
  ) async throws {
    let input = WorkflowMessageAppendInput(
      workflowExecutionId: parentSessionId,
      fromStepId: parentStepId,
      toStepId: directive.joinStepId,
      routingScope: .workflow,
      deliveryKind: .direct,
      sourceStepExecutionId: directive.sourceStepExecutionId,
      transitionCondition: directive.transitionLabel,
      payload: ["fanoutJoin": .object(fanoutJoin)]
    )
    if let nestedInvocationPersistenceStore {
      try await nestedInvocationRecoveryCheckpointer?.reached(.beforeParentPublication)
      _ = try nestedInvocationPersistenceStore.publishFanoutParentMessage(
        parentSessionId: parentSessionId,
        sourceStepExecutionId: directive.sourceStepExecutionId,
        input: input
      )
      try await nestedInvocationRecoveryCheckpointer?.reached(.parentPublicationPersisted)
    }
    _ = try await store.appendWorkflowMessageOnce(input)
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

  private func fanoutContext(from directive: WorkflowFanoutDispatchDirective) throws -> JSONValue? {
    guard let pointer = directive.contextFrom else { return nil }
    guard pointer.hasPrefix("/"), pointer.utf8.count <= 1_024,
          let value = jsonPointerValue(in: .object(directive.sourcePayload), pointer: pointer),
          try JSONEncoder().encode(value).count <= 8_000_000 else {
      throw DeterministicWorkflowRunnerError.fanoutDispatchFailed(
        groupId: directive.groupId, reason: "contextFrom must resolve to a bounded source payload value")
    }
    return value
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
    case .readOnly, .sharedWorkspace:
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

private func fanoutStepOutputs(_ stepIds: [String], session: WorkflowSession) -> JSONObject {
  var outputs: JSONObject = [:]
  for stepId in stepIds {
    if let payload = session.executions.last(where: { $0.stepId == stepId && $0.acceptedOutput != nil })?.acceptedOutput?.payload {
      outputs[stepId] = .object(payload)
    }
  }
  return outputs
}

private struct FanoutBranchOutcome: Sendable {
  var index: Int
  var record: JSONObject
  var resumeError: DeterministicWorkflowRunnerError?

  var isFailure: Bool {
    if resumeError != nil { return false }
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

  static func success(
    index: Int, item: JSONValue, output: JSONObject, sessionId: String, stepOutputs: JSONObject? = nil
  ) -> FanoutBranchOutcome {
    var record: JSONObject = [
      "index": .integer(Int64(index)),
      "item": item,
      "status": .string("completed"),
      "output": .object(output),
      "sessionId": .string(sessionId)
    ]
    if let stepOutputs { record["stepOutputs"] = .object(stepOutputs) }
    return FanoutBranchOutcome(index: index, record: record)
  }

  /// `cancelled` is the real cancellation signal observed by the caller; the
  /// failure text is never inspected to infer it. `stepOutputs` carries the
  /// selected steps that were accepted before the branch stopped; the key is
  /// omitted when none were.
  static func failure(
    index: Int, item: JSONValue, sessionId: String?, reason: String, cancelled: Bool,
    stepOutputs: JSONObject? = nil
  ) -> FanoutBranchOutcome {
    var record: JSONObject = [
      "index": .integer(Int64(index)),
      "item": item,
      "status": .string(cancelled ? "cancelled" : "failed"),
      "failureReason": .string(reason)
    ]
    if let sessionId {
      record["sessionId"] = .string(sessionId)
    }
    if let stepOutputs, !stepOutputs.isEmpty { record["stepOutputs"] = .object(stepOutputs) }
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
