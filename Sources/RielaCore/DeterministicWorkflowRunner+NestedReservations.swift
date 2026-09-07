import Crypto
import Foundation

extension DeterministicWorkflowRunner {
  /// Every executable node type shares the same uncertainty boundary: its
  /// external operation returned, but its accepted output is not durable yet.
  func checkpointNestedEffectCompletion(_ request: DeterministicWorkflowRunRequest) async throws {
    if request.isNestedCalleeEffectBoundary {
      try await nestedInvocationRecoveryCheckpointer?.reached(.afterChildEffect)
    }
  }

  /// Replays a persisted child handoff before executing the parent's stored
  /// resume/join step. The route publication has already advanced the parent
  /// checkpoint, so re-executing that step would allocate a new source
  /// execution identity. Instead, reconstruct the accepted transition from
  /// its durable parent execution and reuse the original reservation.
  func recoverNestedInvocationsBeforeResuming(
    session: WorkflowSession,
    request: DeterministicWorkflowRunRequest
  ) async throws {
    guard request.resumeSessionId != nil,
          let nestedInvocationPersistenceStore,
          let currentStepId = session.currentStepId else {
      return
    }
    let records = try nestedInvocationPersistenceStore.nestedInvocationRecords(parentSessionId: session.sessionId)
    let matching = records.filter { $0.reservation.resumeStepId == currentStepId }
    guard !matching.isEmpty else { return }

    // A crash after the canonical SQLite delivery commit but before the live
    // runtime-store acknowledgement is repaired from the exact saved message.
    for record in matching where record.phase == .delivered {
      if let message = record.parentMessage {
        _ = try await store.appendWorkflowMessageOnce(messageAppendInput(from: message))
      }
    }

    let pending = matching.filter { $0.phase != .delivered }
    for record in pending where record.reservation.branchId == "cross-workflow" {
      guard let execution = session.executions.first(where: {
        $0.executionId == record.reservation.sourceStepExecutionId
      }), let payload = execution.acceptedOutput?.payload,
        let parentStep = request.workflow.steps.first(where: { $0.id == record.reservation.parentStepId }),
        let transition = (parentStep.transitions ?? []).first(where: {
          $0.toWorkflowId == record.reservation.childSnapshot.session.workflowId &&
            $0.resumeStepId == record.reservation.resumeStepId && $0.fanout == nil
        }) else {
        throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested resume cannot reconstruct the persisted cross-workflow transition")
      }
      try await dispatchCrossWorkflowCallee(
        directive: WorkflowCrossWorkflowDispatchDirective(
          workflowId: record.reservation.childSnapshot.session.workflowId,
          calleeEntryStepId: record.reservation.childSnapshot.session.entryStepId,
          resumeStepId: record.reservation.resumeStepId,
          transitionLabel: transition.label,
          handoffPayload: payload,
          sourceStepExecutionId: record.reservation.sourceStepExecutionId
        ),
        parentSessionId: session.sessionId,
        parentStepId: record.reservation.parentStepId,
        request: request
      )
    }

    let fanoutSources = Set(pending.compactMap { record -> String? in
      record.reservation.branchId.hasPrefix("fanout-") ? record.reservation.sourceStepExecutionId : nil
    })
    for sourceExecutionId in fanoutSources {
      guard let record = pending.first(where: { $0.reservation.sourceStepExecutionId == sourceExecutionId }),
            let execution = session.executions.first(where: { $0.executionId == sourceExecutionId }),
            let payload = execution.acceptedOutput?.payload,
            let parentStep = request.workflow.steps.first(where: { $0.id == record.reservation.parentStepId }),
            let transition = (parentStep.transitions ?? []).first(where: {
              $0.fanout != nil && $0.fanout?.joinStepId == record.reservation.resumeStepId
            }), let fanout = transition.fanout else {
        throw WorkflowRuntimePersistenceStoreError.sqliteFailed("nested resume cannot reconstruct the persisted fanout transition")
      }
      _ = try await dispatchFanout(
        directive: WorkflowFanoutDispatchDirective(
          groupId: fanout.groupId,
          workflowId: transition.toWorkflowId,
          sourceStepId: record.reservation.parentStepId,
          targetStepId: transition.toStepId,
          joinStepId: fanout.joinStepId,
          transitionLabel: transition.label,
          sourceStepExecutionId: sourceExecutionId,
          itemsFrom: fanout.itemsFrom,
          itemVariable: fanout.itemVariable,
          concurrency: fanout.concurrency,
          failurePolicy: fanout.failurePolicy ?? .failFast,
          resultOrder: fanout.resultOrder ?? .input,
          writeOwnership: fanout.writeOwnership,
          sourcePayload: payload,
          dependencies: fanout.dependencies,
          changeTracking: fanout.changeTracking
        ),
        parentSessionId: session.sessionId,
        parentStepId: record.reservation.parentStepId,
        request: request
      )
    }
  }

  private func messageAppendInput(from message: WorkflowMessageRecord) -> WorkflowMessageAppendInput {
    WorkflowMessageAppendInput(
      workflowExecutionId: message.workflowExecutionId,
      fromStepId: message.fromStepId,
      toStepId: message.toStepId,
      routingScope: message.routingScope,
      deliveryKind: message.deliveryKind,
      sourceStepExecutionId: message.sourceStepExecutionId,
      transitionCondition: message.transitionCondition,
      payload: message.payload,
      artifactRefs: message.artifactRefs
    )
  }

  /// Reserves a stable child session before its first node may run. A resumed
  /// parent therefore reuses its original child identity rather than creating
  /// another nested invocation.
  func reserveNestedSession(
    workflow: WorkflowDefinition,
    nodePayloads: [String: AgentNodePayload],
    entryStepId: String,
    parentSessionId: String,
    rootSessionId: String,
    parentStepId: String,
    resumeStepId: String,
    sourceExecutionId: String,
    branchId: String
  ) async throws -> String {
    if let nestedInvocationPersistenceStore,
       let existing = try nestedInvocationPersistenceStore.nestedInvocationRecord(
         parentSessionId: parentSessionId,
         sourceStepExecutionId: sourceExecutionId,
         branchId: branchId
       ) {
      let persisted = existing.reservation.childSnapshot.session
      guard persisted.workflowId == workflow.workflowId,
            persisted.entryStepId == entryStepId,
            persisted.parentSessionId == parentSessionId,
            persisted.rootSessionId == rootSessionId else {
        throw WorkflowRuntimePersistenceStoreError.sqliteFailed(
          "nested invocation reservation conflicts with durable identity"
        )
      }
      // The prepared snapshot is immutable identity. In particular, do not
      // rebuild it from a now-terminal in-memory child when reopening after a
      // node result or parent-publication crash boundary.
      // Older journals can contain the former FNV child id. Their durable
      // reservation key is still authoritative for recovery; only newly
      // allocated child sessions use the versioned SHA-256 identity below.
      try await nestedInvocationRecoveryCheckpointer?.reached(.parentIntentPersisted)
      return persisted.sessionId
    }
    let sessionId = try nestedSessionID(
      parentSessionId: parentSessionId,
      sourceExecutionId: sourceExecutionId,
      branchId: branchId
    )
    let child = try await store.createSession(WorkflowSessionCreateInput(
      sessionId: sessionId,
      workflowId: workflow.workflowId,
      entryStepId: entryStepId,
      parentSessionId: parentSessionId,
      rootSessionId: rootSessionId
    ))
    if let nestedInvocationPersistenceStore {
      try nestedInvocationPersistenceStore.reserveNestedInvocation(WorkflowNestedInvocationReservation(
        parentSessionId: parentSessionId,
        parentStepId: parentStepId,
        resumeStepId: resumeStepId,
        sourceStepExecutionId: sourceExecutionId,
        branchId: branchId,
        childSnapshot: WorkflowRuntimePersistenceSnapshot(session: child),
        calleeWorkflow: workflow,
        calleeNodePayloads: nodePayloads,
        calleeRevision: nestedCalleeRevision(workflow: workflow, nodePayloads: nodePayloads)
      ))
      try await nestedInvocationRecoveryCheckpointer?.reached(.prepared)
    }
    return child.sessionId
  }

  /// A durable child identity is derived from an unambiguous binary framing of
  /// the three persisted invocation components. The versioned SHA-256 digest
  /// prevents a delimiter-bearing component from aliasing another tuple and
  /// makes accidental identity collisions impractical.
  func nestedSessionID(parentSessionId: String, sourceExecutionId: String, branchId: String) throws -> String {
    let components = [parentSessionId, sourceExecutionId, branchId]
    guard components.allSatisfy(isSafeNestedIdentityComponent) else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed(
        "nested child identity contains an unsafe identifier component"
      )
    }
    return "nested-v1-\(canonicalNestedIdentityDigest(domain: "riela.nested-session.v1", components: components))"
  }

  func appendNestedResultOnce(
    parentSessionId: String,
    parentStepId: String,
    resumeStepId: String,
    sourceExecutionId: String,
    transitionCondition: String?,
    childSessionId: String,
    workflowId: String,
    status: WorkflowSessionStatus,
    payload: JSONObject,
    terminalSession: WorkflowSession
  ) async throws {
    var resumePayload = payload
    resumePayload["_rielaCrossWorkflow"] = .object([
      "workflowId": .string(workflowId),
      "sessionId": .string(childSessionId),
      "status": .string(status.rawValue)
    ])
    let messageInput = WorkflowMessageAppendInput(
      workflowExecutionId: parentSessionId,
      fromStepId: parentStepId,
      toStepId: resumeStepId,
      routingScope: .workflow,
      deliveryKind: .direct,
      sourceStepExecutionId: sourceExecutionId,
      transitionCondition: transitionCondition,
      payload: resumePayload
    )
    if let nestedInvocationPersistenceStore {
      let childMessages = try await store.listMessages(for: childSessionId, toStepId: nil)
      guard let record = try nestedInvocationPersistenceStore.nestedInvocationRecord(
        parentSessionId: parentSessionId,
        sourceStepExecutionId: sourceExecutionId,
        branchId: "cross-workflow"
      ), record.reservation.childSnapshot.session.sessionId == childSessionId else {
        throw WorkflowRuntimePersistenceStoreError.notFound("persisted cross-workflow reservation not found")
      }
      if record.childTerminalSnapshot == nil {
        _ = try nestedInvocationPersistenceStore.recordNestedChildTerminal(
          reservation: record.reservation,
          terminalSnapshot: WorkflowRuntimePersistenceSnapshot(session: terminalSession, workflowMessages: childMessages)
        )
        try await nestedInvocationRecoveryCheckpointer?.reached(.childTerminalPersisted)
      } else {
        guard record.childTerminalSnapshot?.session.sessionId == childSessionId,
              record.childTerminalSnapshot?.session.status == terminalSession.status else {
          throw WorkflowRuntimePersistenceStoreError.sqliteFailed(
            "nested child terminal conflicts with durable result"
          )
        }
      }
      try await nestedInvocationRecoveryCheckpointer?.reached(.beforeParentPublication)
      _ = try nestedInvocationPersistenceStore.publishNestedParentMessage(reservation: record.reservation, input: messageInput)
      try await nestedInvocationRecoveryCheckpointer?.reached(.parentPublicationPersisted)
    }
    _ = try await store.appendWorkflowMessageOnce(messageInput)
  }

  /// Commits the actual child terminal snapshot before exposing a checkpoint
  /// after its node result. A restarted runner can therefore reconstruct the
  /// effect solely from canonical SQLite instead of relying on an in-memory
  /// child session that disappeared with the former process.
  @discardableResult
  func persistNestedTerminalIfNeeded(
    parentSessionId: String,
    sourceExecutionId: String,
    branchId: String,
    terminalSession: WorkflowSession
  ) async throws -> Bool {
    guard let nestedInvocationPersistenceStore,
          let record = try nestedInvocationPersistenceStore.nestedInvocationRecord(
            parentSessionId: parentSessionId,
            sourceStepExecutionId: sourceExecutionId,
            branchId: branchId
          ) else {
      return false
    }
    if let terminal = record.childTerminalSnapshot {
      guard terminal.session.sessionId == terminalSession.sessionId,
            terminal.session.status == terminalSession.status else {
        throw WorkflowRuntimePersistenceStoreError.sqliteFailed(
          "nested child terminal conflicts with durable result"
        )
      }
      return false
    }
    let childMessages = try await store.listMessages(for: terminalSession.sessionId, toStepId: nil)
    _ = try nestedInvocationPersistenceStore.recordNestedChildTerminal(
      reservation: record.reservation,
      terminalSnapshot: WorkflowRuntimePersistenceSnapshot(session: terminalSession, workflowMessages: childMessages)
    )
    return true
  }
}

private func isSafeNestedIdentityComponent(_ value: String) -> Bool {
  let bytes = Array(value.utf8)
  guard (1...128).contains(bytes.count), let first = bytes.first,
        isASCIIAlphaNumeric(first) else {
    return false
  }
  return bytes.dropFirst().allSatisfy { isASCIIAlphaNumeric($0) || $0 == 46 || $0 == 45 || $0 == 95 }
}

private func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
  (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
}

/// Uses count-prefixed UTF-8 rather than a textual delimiter. Keep this
/// separate from user-controlled identifiers so the persisted format remains
/// stable and independently reproducible.
private func canonicalNestedIdentityDigest(domain: String, components: [String]) -> String {
  var material = Data()
  appendNestedIdentityComponent(domain, to: &material)
  appendNestedIdentityComponent(String(components.count), to: &material)
  for component in components {
    appendNestedIdentityComponent(component, to: &material)
  }
  return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
}

private func appendNestedIdentityComponent(_ component: String, to material: inout Data) {
  let bytes = Data(component.utf8)
  var length = UInt64(bytes.count).bigEndian
  withUnsafeBytes(of: &length) { material.append(contentsOf: $0) }
  material.append(bytes)
}
