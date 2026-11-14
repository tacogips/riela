import Foundation
import RielaCore

public struct HandoverPacketBuilderInput: Sendable {
  public var handoverId: HandoverID
  public var task: WorkTask
  public var attempt: Attempt
  public var reason: HandoverReason
  public var resumeStepId: String
  public var snapshot: WorkflowRuntimePersistenceSnapshot
  public var workflow: WorkflowDefinition
  public var workflowRef: HandoverWorkflowRef
  public var deliverables: [DeliverableRef]
  public var variables: JSONObject
  public var progressNote: String?
  public var hostId: String
  public var producer: EvidenceProducer
  public var redaction: HandoverRedactionRules
  public var now: Date

  public init(handoverId: HandoverID, task: WorkTask, attempt: Attempt, reason: HandoverReason,
              resumeStepId: String, snapshot: WorkflowRuntimePersistenceSnapshot, workflow: WorkflowDefinition,
              workflowRef: HandoverWorkflowRef, deliverables: [DeliverableRef] = [], variables: JSONObject = [:],
              progressNote: String? = nil, hostId: String, producer: EvidenceProducer,
              redaction: HandoverRedactionRules = HandoverRedactionRules(), now: Date) {
    self.handoverId = handoverId; self.task = task; self.attempt = attempt; self.reason = reason
    self.resumeStepId = resumeStepId; self.snapshot = snapshot; self.workflow = workflow
    self.workflowRef = workflowRef; self.deliverables = deliverables; self.variables = variables
    self.progressNote = progressNote; self.hostId = hostId; self.producer = producer; self.redaction = redaction; self.now = now
  }
}

public struct HandoverPacketBuilder: Sendable {
  private let store: WorkStore
  public init(store: WorkStore) { self.store = store }

  public func build(_ input: HandoverPacketBuilderInput) throws -> HandoverPacket {
    let accepted = input.snapshot.session.executions.filter { $0.acceptedOutput != nil && $0.status == .completed }
    let acceptedIds = Set(accepted.map(\.executionId))
    let summaries = try accepted.map { execution -> HandoverStepSummary in
      guard let output = execution.acceptedOutput?.payload else { throw WorkStoreError("accepted handover step lost its output") }
      let outputValue = HandoverRedactionRules.apply(.object(output), rules: input.redaction)
      let encoded = try JSONCanonical.encode(outputValue)
      let bounded: JSONObject
      if encoded.count > HandoverBounds.acceptedOutput {
        bounded = ["truncated": .bool(true), "bytes": .integer(Int64(encoded.count))]
      } else if case let .object(value) = outputValue { bounded = value } else { bounded = [:] }
      return HandoverStepSummary(stepId: execution.stepId, stepExecutionId: execution.executionId, status: execution.status,
                                 acceptedOutput: bounded, responseExcerpt: Self.suffix(execution.streamedResponseText ?? "", maxBytes: HandoverBounds.responseExcerpt),
                                 backend: execution.backend?.rawValue)
    }
    let messages = input.snapshot.workflowMessages.filter { acceptedIds.contains($0.sourceStepExecutionId) }.map { message -> WorkflowMessageRecord in
      var copy = message
      copy.payload = HandoverRedactionRules.apply(message.payload, rules: input.redaction)
      return copy
    }
    let historyExecutions = accepted.map { execution in
      var preserved = Self.preservedHistory(execution)
      if let output = preserved.acceptedOutput?.payload {
        preserved.acceptedOutput?.payload = HandoverRedactionRules.apply(output, rules: input.redaction)
      }
      if let snapshot = preserved.inputSnapshot { preserved.inputSnapshot = HandoverRedactionRules.apply(snapshot, rules: input.redaction) }
      return preserved
    }
    let compatibility = accepted.compactMap { execution -> (String, String)? in
      guard let value = execution.inputSnapshot?["_rielaHistoryContract"],
            case let .object(contract) = value,
            case let .string(digest)? = contract["workflowDigest"] else { return nil }
      return (execution.stepId, digest)
    }.reduce(into: [String: String]()) { $0[$1.0] = $1.1 }
    var history = HandoverHistoryBundle(executions: historyExecutions, messages: messages,
                                        compatibilityDigests: compatibility, truncated: false)
    if try JSONCanonical.encode(history).count > HandoverBounds.history {
      history = HandoverHistoryBundle(executions: [], messages: [], compatibilityDigests: [:], truncated: true)
    }
    var variables = input.variables.filter { $0.key != "handover" && $0.key != "rielaTask" }
    variables = HandoverRedactionRules.apply(variables, rules: input.redaction)
    if try JSONCanonical.encode(variables).count > HandoverBounds.variables { variables = ["truncated": .bool(true)] }
    let evidence = try store.listEvidence(taskId: input.task.id)
    var evidenceCounts: [String: Int] = [:]
    evidence.forEach { evidenceCounts[$0.kind.rawValue, default: 0] += 1 }
    var costs: [String: LoopCostEvidence] = [:]
    for previousAttempt in try store.listAttempts(taskId: input.task.id) {
      for cost in previousAttempt.outcome?.costs ?? [] {
        costs["\(previousAttempt.id.rawValue)\u{0}\(cost.stepExecutionId)"] = cost
      }
    }
    for item in evidence where item.kind == .cost {
      guard let raw = item.payloadRef.inlinePayload,
            let cost = try? JSONCanonical.decoder().decode(LoopCostEvidence.self, from: JSONCanonical.encode(raw)),
            let attemptId = item.attemptId else { continue }
      costs["\(attemptId.rawValue)\u{0}\(cost.stepExecutionId)"] = cost
    }
    let budget = input.task.guardPolicy.budget
    let tokens = costs.values.compactMap(\.totalTokens).reduce(0, +)
    let wall = costs.values.compactMap(\.durationMs).reduce(0, +)
    let gateResults = input.attempt.outcome?.latestGateResults ?? Self.gates(evidence)
    let progress = HandoverProgress(acceptedSteps: summaries, remainingSteps: Self.remainingSteps(workflow: input.workflow, from: input.resumeStepId),
                                   latestGateResults: gateResults, openFindings: try store.listFindings(taskId: input.task.id, status: .open),
                                   evidenceSummary: evidenceCounts, remainingBudget: BudgetSnapshot(attemptsUsed: try store.listAttempts(taskId: input.task.id).count,
                                     maxAttempts: budget?.maxAttempts, tokensUsed: tokens, maxTotalTokens: budget?.maxTotalTokens,
                                     wallClockMsUsed: wall, maxWallClockMs: budget?.maxWallClockMs))
    let note = input.progressNote.map { Self.suffix($0, maxBytes: HandoverBounds.progressNote) }
      .map { HandoverRedactionRules.apply(.string($0), rules: input.redaction) }
    let progressNote: String?
    if case let .string(redactedNote)? = note { progressNote = redactedNote } else { progressNote = nil }
    var packet = HandoverPacket(id: input.handoverId, taskId: input.task.id, intentId: input.task.intentId,
      fromAttemptId: input.attempt.id, fromSessionId: input.attempt.sessionId, generation: input.attempt.generation,
      reason: input.reason, workflow: input.workflowRef, progress: progress, history: history, variables: variables,
      deliverables: input.deliverables, contract: HandoverContinuationContract(resumeStepId: input.resumeStepId,
        completion: input.task.completion, verification: input.task.completion.verification, guardPolicy: input.task.guardPolicy),
      brief: "", producedBy: input.producer, producedOn: input.hostId, createdAt: input.now)
    packet.brief = Self.clipped(HandoverBriefRenderer().render(packet, progressNote: progressNote), maxBytes: HandoverBounds.brief, suffix: "…(brief truncated)\n")
    packet = try packet.sealed()
    guard try JSONCanonical.encode(packet).count <= HandoverBounds.packet else { throw WorkStoreError("handover packet exceeds 4 MiB") }
    return packet
  }

  private static func remainingSteps(workflow: WorkflowDefinition, from start: String) -> [String] {
    var queue = [start], visited = Set<String>(), result: [String] = []
    let byId = Dictionary(uniqueKeysWithValues: workflow.steps.map { ($0.id, $0) })
    while !queue.isEmpty {
      let step = queue.removeFirst()
      guard visited.insert(step).inserted else { continue }
      result.append(step)
      queue += byId[step]?.transitions?.map(\.toStepId) ?? []
    }
    return result
  }

  private static func preservedHistory(_ source: WorkflowStepExecution) -> WorkflowStepExecution {
    var value = source
    value.backend = nil; value.backendSessionId = nil; value.backendWorkingDirectory = nil; value.usage = nil
    value.lastBackendEventAt = nil; value.lastBackendEventType = nil; value.backendEventCount = nil
    value.recentBackendEvents = []; value.pendingRoutePublication = nil
    value.streamedResponseText = nil; value.adapterOutput = nil; value.acceptedOutput?.runtimeFinalizationToken = nil
    return value
  }

  private static func suffix(_ value: String, maxBytes: Int) -> String {
    var start = value.endIndex
    var count = 0
    while start > value.startIndex {
      let previous = value.index(before: start)
      let size = value[previous..<start].utf8.count
      if count + size > maxBytes { break }
      count += size; start = previous
    }
    return String(value[start...])
  }

  private static func clipped(_ value: String, maxBytes: Int, suffix: String) -> String {
    guard value.utf8.count > maxBytes else { return value }
    let kept = suffix.isEmpty ? "" : suffix
    let prefix = String(value.prefix { _ in true })
    var output = ""
    for character in prefix {
      guard (output + String(character) + kept).utf8.count <= maxBytes else { break }
      output.append(character)
    }
    return output + kept
  }

  private static func gates(_ evidence: [Evidence]) -> [LoopGateResult] {
    var latest: [String: (Date, LoopGateResult)] = [:]
    for item in evidence where item.kind == .gate {
      guard let payload = item.payloadRef.inlinePayload,
            let data = try? JSONCanonical.encode(payload),
            let result = try? JSONCanonical.decoder().decode(LoopGateResult.self, from: data) else { continue }
      let previousDate = latest[result.gateId]?.0 ?? .distantPast
      if previousDate <= item.createdAt { latest[result.gateId] = (item.createdAt, result) }
    }
    return latest.keys.sorted().compactMap { latest[$0]?.1 }
  }
}
