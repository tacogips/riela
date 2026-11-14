import Foundation

enum DynamicWorkflowIterationPlan {
  case overBudget(maxIterations: Int)
  case invalid(iteration: Int, workflowId: String?, rationale: String?, diagnostics: [WorkflowValidationDiagnostic], bounds: ResolvedDynamicWorkflowBounds)
  case valid(
    iteration: Int,
    workflow: WorkflowDefinition,
    nodePayloads: [String: AgentNodePayload],
    digest: String,
    origin: WorkflowGeneratedWorkflowOrigin,
    rationale: String?,
    input: JSONObject,
    bounds: ResolvedDynamicWorkflowBounds
  )
}

struct DynamicWorkflowResultDelivery {
  var parentSessionId: String
  var parentStepId: String
  var resumeStepId: String
  var sourceExecutionId: String
  var transitionLabel: String?
  var iteration: Int
  var bounds: ResolvedDynamicWorkflowBounds
  var outcome: String
  var childSessionId: String?
  var workflowId: String?
  var definitionDigest: String?
  var rationale: String?
  var rootOutput: JSONObject
  var failureKind: WorkflowSessionFailureKind?
  var failureReason: String?
  var diagnostics: [WorkflowValidationDiagnostic]
  var terminalSession: WorkflowSession?
  var childStatus: WorkflowSessionStatus
}

extension DeterministicWorkflowRunner {
  func prepareDynamicIteration(
    sessionId: String,
    sourceStepExecutionId: String,
    step: WorkflowStepRef,
    transition: WorkflowDynamicWorkflowTransition,
    envelope: JSONObject,
    request: DeterministicWorkflowRunRequest
  ) async throws -> DynamicWorkflowIterationPlan {
    let bounds = DynamicWorkflowPolicy.resolve(transition, parentNodePayloads: request.nodePayloads)
    let messages = try await store.listMessages(for: sessionId, toStepId: step.transitions?.first(where: { $0.dynamicWorkflow == transition })?.toStepId)
    var priorSources = Set(messages.compactMap { message -> String? in
      message.payload["dynamicWorkflowResult"] == nil || message.sourceStepExecutionId == sourceStepExecutionId
        ? nil
        : message.sourceStepExecutionId
    })
    if let nestedInvocationPersistenceStore {
      for record in try nestedInvocationPersistenceStore.nestedInvocationRecords(parentSessionId: sessionId)
      where record.reservation.branchId == "dynamic-workflow" && record.reservation.sourceStepExecutionId != sourceStepExecutionId {
        priorSources.insert(record.reservation.sourceStepExecutionId)
      }
    }
    let iteration = priorSources.count + 1
    guard iteration <= bounds.maxIterations else {
      return .overBudget(maxIterations: bounds.maxIterations)
    }

    let rationale: String? = {
      guard case let .string(value)? = envelope["rationale"] else { return nil }
      return value
    }()
    let workflowId: String? = {
      guard case let .object(workflow)? = envelope["workflow"],
            case let .string(id)? = workflow["workflowId"] else { return nil }
      return id
    }()
    var diagnostics = DynamicWorkflowPolicy.check(
      envelope: envelope,
      parentWorkflowId: request.workflow.workflowId,
      bounds: bounds
    )
    if diagnostics.contains(where: { $0.severity == .error }) {
      return .invalid(iteration: iteration, workflowId: workflowId, rationale: rationale, diagnostics: diagnostics, bounds: bounds)
    }

    guard let data = try? JSONEncoder().encode(envelope),
          let payload = try? JSONDecoder().decode(TemporaryWorkflowPayload.self, from: data) else {
      diagnostics.append(WorkflowValidationDiagnostic(severity: .error, path: "envelope", message: "must contain a valid workflow and nodePayloads object"))
      return .invalid(iteration: iteration, workflowId: workflowId, rationale: rationale, diagnostics: diagnostics, bounds: bounds)
    }
    let materialized = materializeTemporaryWorkflowPayload(payload)
    diagnostics.append(contentsOf: materialized.validation.diagnostics)
    guard var generatedWorkflow = materialized.validation.workflow else {
      return .invalid(iteration: iteration, workflowId: workflowId, rationale: rationale, diagnostics: diagnostics, bounds: bounds)
    }
    let emitterPayload = request.nodePayloads[step.nodeId]
    var stampedPayloads = materialized.nodePayloads
    for nodeId in stampedPayloads.keys.sorted() {
      guard var payload = stampedPayloads[nodeId] else { continue }
      payload.agentSandbox = emitterPayload?.agentSandbox
      payload.agentToolPolicy = emitterPayload?.agentToolPolicy
      stampedPayloads[nodeId] = payload
    }
    let parentTimeout = request.defaultTimeoutMs ?? request.workflow.defaults.nodeTimeoutMs
    generatedWorkflow.defaults.nodeTimeoutMs = min(generatedWorkflow.defaults.nodeTimeoutMs, parentTimeout)
    generatedWorkflow.defaults.maxLoopIterations = min(
      generatedWorkflow.defaults.maxLoopIterations,
      request.maxLoopIterations ?? request.workflow.defaults.maxLoopIterations
    )
    for index in generatedWorkflow.steps.indices {
      if let timeout = generatedWorkflow.steps[index].timeoutMs {
        generatedWorkflow.steps[index].timeoutMs = min(timeout, parentTimeout)
      }
    }
    diagnostics.append(contentsOf: DefaultWorkflowValidator().validate(generatedWorkflow, nodePayloads: stampedPayloads))
    guard !diagnostics.contains(where: { $0.severity == .error }) else {
      return .invalid(iteration: iteration, workflowId: generatedWorkflow.workflowId, rationale: rationale, diagnostics: diagnostics, bounds: bounds)
    }
    let digest = nestedCalleeRevision(workflow: generatedWorkflow, nodePayloads: stampedPayloads)
    let origin = WorkflowGeneratedWorkflowOrigin(
      iteration: iteration,
      definitionDigest: digest,
      sourceStepExecutionId: sourceStepExecutionId,
      rationale: rationale
    )
    let input: JSONObject
    if case let .object(value)? = envelope["input"] { input = value } else { input = [:] }
    return .valid(
      iteration: iteration,
      workflow: generatedWorkflow,
      nodePayloads: stampedPayloads,
      digest: digest,
      origin: origin,
      rationale: rationale,
      input: input,
      bounds: bounds
    )
  }

  func dispatchDynamicWorkflow(
    directive: WorkflowDynamicWorkflowDispatchDirective,
    parentSessionId: String,
    parentStepId: String,
    request: DeterministicWorkflowRunRequest
  ) async throws {
    guard let step = request.workflow.steps.first(where: { $0.id == parentStepId }) else {
      throw DeterministicWorkflowRunnerError.invalidWorkflow("dynamic workflow source step '\(parentStepId)' does not exist")
    }
    let plan = try await prepareDynamicIteration(
      sessionId: parentSessionId,
      sourceStepExecutionId: directive.sourceStepExecutionId,
      step: step,
      transition: directive.transition,
      envelope: directive.envelope,
      request: request
    )
    switch plan {
    case let .overBudget(maxIterations):
      throw DeterministicWorkflowRunnerError.loopBudgetExceeded(
        "dynamic workflow iteration budget exhausted (\(maxIterations))"
      )
    case let .invalid(iteration, workflowId, rationale, diagnostics, bounds):
      if bounds.onFailure == .fail {
        throw dynamicWorkflowFailure(workflowId: workflowId ?? "generated", diagnostics: diagnostics)
      }
      try await appendDynamicWorkflowResult(DynamicWorkflowResultDelivery(
        parentSessionId: parentSessionId,
        parentStepId: parentStepId,
        resumeStepId: directive.resumeStepId,
        sourceExecutionId: directive.sourceStepExecutionId,
        transitionLabel: directive.transitionLabel,
        iteration: iteration,
        bounds: bounds,
        outcome: "invalid",
        childSessionId: nil,
        workflowId: workflowId,
        definitionDigest: nil,
        rationale: rationale,
        rootOutput: [:],
        failureKind: nil,
        failureReason: nil,
        diagnostics: diagnostics,
        terminalSession: nil,
        childStatus: .completed
      ))
    case let .valid(iteration, workflow, nodePayloads, digest, origin, rationale, input, bounds):
      let rootSessionId = request.rootSessionId ?? parentSessionId
      var executionWorkflow = workflow
      var executionNodePayloads = nodePayloads
      var executionOrigin = origin
      let existingRecord = try nestedInvocationPersistenceStore?.nestedInvocationRecord(
        parentSessionId: parentSessionId,
        sourceStepExecutionId: directive.sourceStepExecutionId,
        branchId: "dynamic-workflow"
      )
      if let existingRecord {
        guard let persistedWorkflow = existingRecord.reservation.calleeWorkflow,
              let persistedPayloads = existingRecord.reservation.calleeNodePayloads,
              existingRecord.reservation.calleeRevision == digest,
              existingRecord.reservation.calleeRevision == nestedCalleeRevision(
                workflow: persistedWorkflow,
                nodePayloads: persistedPayloads
              ) else {
          throw DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(
            workflowId: workflow.workflowId,
            reason: "persisted dynamic workflow definition digest does not match"
          )
        }
        executionWorkflow = persistedWorkflow
        executionNodePayloads = persistedPayloads
        executionOrigin = existingRecord.reservation.childSnapshot.session.generatedWorkflow ?? origin
      }
      let childSessionId = try await reserveNestedSession(
        workflow: executionWorkflow,
        nodePayloads: executionNodePayloads,
        entryStepId: executionWorkflow.entryStepId,
        parentSessionId: parentSessionId,
        rootSessionId: rootSessionId,
        parentStepId: parentStepId,
        resumeStepId: directive.resumeStepId,
        sourceExecutionId: directive.sourceStepExecutionId,
        branchId: "dynamic-workflow",
        generatedWorkflow: executionOrigin
      )
      if let record = existingRecord, let nestedInvocationPersistenceStore {
        if let reason = record.recoveryReason {
          throw DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(workflowId: workflow.workflowId, reason: reason)
        }
        if record.parentMessage != nil { return }
        if record.childTerminalSnapshot == nil,
           let child = try? nestedInvocationPersistenceStore.load(sessionId: childSessionId),
           child.session.status == .running {
          _ = try nestedInvocationPersistenceStore.requireNestedInvocationRecovery(
            reservation: record.reservation,
            reason: "child was running without a terminal receipt"
          )
          throw DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(
            workflowId: workflow.workflowId,
            reason: "nested child '\(childSessionId)' has an unresolved in-flight effect"
          )
        }
      }

      var childRequest = DeterministicWorkflowRunRequest(
        workflow: executionWorkflow,
        nodePayloads: executionNodePayloads,
        variables: input,
        maxSteps: bounds.childMaxSteps,
        maxLoopIterations: request.maxLoopIterations,
        disableDefaultLoopGuard: request.disableDefaultLoopGuard,
        defaultTimeoutMs: request.defaultTimeoutMs,
        timeoutMs: request.timeoutMs,
        memoryRootDirectory: request.memoryRootDirectory,
        agentSilenceWarningMs: request.agentSilenceWarningMs,
        agentSilenceMonitorIntervalMs: request.agentSilenceMonitorIntervalMs,
        eventHandler: request.eventHandler,
        sessionExecutionAdmission: request.sessionExecutionAdmission,
        crossWorkflowDispatchDepth: request.crossWorkflowDispatchDepth + 1
      )
      childRequest.workflowRunId = request.workflowRunId
      childRequest.fanoutChangeContext = request.fanoutChangeContext
      childRequest.parentSessionId = parentSessionId
      childRequest.rootSessionId = rootSessionId
      childRequest.resumeSessionId = childSessionId
      childRequest.isNestedCalleeEffectBoundary = true
      var outcome = "completed"
      var childStatus: WorkflowSessionStatus = .completed
      var rootOutput: JSONObject = [:]
      var failureKind: WorkflowSessionFailureKind?
      var failureReason: String?
      var terminalSession: WorkflowSession?
      do {
        try await nestedInvocationRecoveryCheckpointer?.reached(.beforeChildNodeEffect)
        let result = try await run(childRequest)
        terminalSession = result.session
        childStatus = result.status
        rootOutput = result.rootOutput ?? [:]
        if result.status != .completed {
          outcome = result.status == .cancelled ? "cancelled" : "failed"
          failureKind = result.session.failureKind
          failureReason = result.session.failureReason
        }
      } catch {
        if isWorkflowRunCancellation(error) && Task.isCancelled { throw error }
        if error is NestedRecoveryInterruption { throw error }
        terminalSession = try? await store.loadSession(id: childSessionId)
        childStatus = terminalSession?.status ?? .failed
        outcome = childStatus == .cancelled ? "cancelled" : "failed"
        failureKind = terminalSession?.failureKind ?? workflowRunFailureKind(error)
        failureReason = terminalSession?.failureReason ?? workflowRunFailureReason(error)
        if isWorkflowRunCancellation(error) && Task.isCancelled { throw error }
      }
      if let terminalSession {
        _ = try await persistNestedTerminalIfNeeded(
          parentSessionId: parentSessionId,
          sourceExecutionId: directive.sourceStepExecutionId,
          branchId: "dynamic-workflow",
          terminalSession: terminalSession
        )
      }
      if outcome != "completed", bounds.onFailure == .fail {
        throw dynamicWorkflowFailure(workflowId: executionWorkflow.workflowId, diagnostics: [])
      }
      try await appendDynamicWorkflowResult(DynamicWorkflowResultDelivery(
        parentSessionId: parentSessionId,
        parentStepId: parentStepId,
        resumeStepId: directive.resumeStepId,
        sourceExecutionId: directive.sourceStepExecutionId,
        transitionLabel: directive.transitionLabel,
        iteration: iteration,
        bounds: bounds,
        outcome: outcome,
        childSessionId: childSessionId,
        workflowId: executionWorkflow.workflowId,
        definitionDigest: digest,
        rationale: rationale,
        rootOutput: rootOutput,
        failureKind: failureKind,
        failureReason: failureReason,
        diagnostics: [],
        terminalSession: terminalSession,
        childStatus: childStatus
      ))
    }
  }

  func appendDynamicWorkflowResult(_ delivery: DynamicWorkflowResultDelivery) async throws {
    let diagnosticValues: [JSONValue] = delivery.diagnostics.map { diagnostic in
      .object(["severity": .string(diagnostic.severity.rawValue), "path": .string(diagnostic.path), "message": .string(diagnostic.message)])
    }
    let result: JSONObject = [
      "iteration": .number(Double(delivery.iteration)),
      "maxIterations": .number(Double(delivery.bounds.maxIterations)),
      "outcome": .string(delivery.outcome),
      "childSessionId": delivery.childSessionId.map(JSONValue.string) ?? .null,
      "workflowId": delivery.workflowId.map(JSONValue.string) ?? .null,
      "definitionDigest": delivery.definitionDigest.map(JSONValue.string) ?? .null,
      "rationale": delivery.rationale.map(JSONValue.string) ?? .null,
      "rootOutput": .object(delivery.rootOutput),
      "failureKind": delivery.failureKind.map { .string($0.rawValue) } ?? .null,
      "failureReason": delivery.failureReason.map(JSONValue.string) ?? .null,
      "diagnostics": .array(diagnosticValues)
    ]
    let message = WorkflowMessageAppendInput(
      workflowExecutionId: delivery.parentSessionId,
      fromStepId: delivery.parentStepId,
      toStepId: delivery.resumeStepId,
      routingScope: .workflow,
      deliveryKind: .direct,
      sourceStepExecutionId: delivery.sourceExecutionId,
      transitionCondition: delivery.transitionLabel,
      payload: ["dynamicWorkflowResult": .object(result)]
    )
    if let terminalSession = delivery.terminalSession, let childSessionId = delivery.childSessionId {
      try await appendNestedResultOnce(
        parentSessionId: delivery.parentSessionId,
        parentStepId: delivery.parentStepId,
        resumeStepId: delivery.resumeStepId,
        sourceExecutionId: delivery.sourceExecutionId,
        transitionCondition: delivery.transitionLabel,
        childSessionId: childSessionId,
        workflowId: delivery.workflowId ?? terminalSession.workflowId,
        status: delivery.childStatus,
        payload: [:],
        terminalSession: terminalSession,
        branchId: "dynamic-workflow",
        payloadOverride: message.payload
      )
    } else {
      if delivery.outcome == "invalid" {
        try await nestedInvocationRecoveryCheckpointer?.reached(.beforeParentPublication)
      }
      _ = try await store.appendWorkflowMessageOnce(message)
    }
  }

  private func dynamicWorkflowFailure(workflowId: String, diagnostics: [WorkflowValidationDiagnostic]) -> Error {
    let messages = diagnostics.prefix(5).map(\.message).joined(separator: "; ")
    let reason = messages.isEmpty ? "generated workflow child failed" : "invalid generated workflow: \(messages)"
    return DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(workflowId: workflowId, reason: reason)
  }
}
