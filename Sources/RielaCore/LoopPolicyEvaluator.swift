import Foundation

public struct LoopPolicyStepDecision: Codable, Equatable, Sendable {
  public var stepId: String
  public var nodeId: String
  public var allowed: Bool
  public var decisions: [LoopPolicyDecision]
  public var denials: [LoopPolicyDecision]

  public init(
    stepId: String,
    nodeId: String,
    allowed: Bool,
    decisions: [LoopPolicyDecision] = [],
    denials: [LoopPolicyDecision] = []
  ) {
    self.stepId = stepId
    self.nodeId = nodeId
    self.allowed = allowed
    self.decisions = decisions
    self.denials = denials
  }
}

public protocol LoopPolicyEvaluating: Sendable {
  func preflight(workflow: WorkflowDefinition, nodePayloads: [String: AgentNodePayload]) -> LoopPolicyEvidence
  func evaluateStep(
    step: WorkflowStepRef,
    node: AgentNodePayload,
    workflowPolicy: LoopPolicyDeclaration?
  ) -> LoopPolicyStepDecision
}

public struct DefaultLoopPolicyEvaluator: LoopPolicyEvaluating {
  public init() {}

  public func preflight(
    workflow: WorkflowDefinition,
    nodePayloads: [String: AgentNodePayload]
  ) -> LoopPolicyEvidence {
    guard let loop = workflow.loop else {
      return LoopPolicyEvidence()
    }

    let effective = effectivePolicy(from: loop.policies)
    var decisions = baselineDecisions(for: effective)
    var denials: [LoopPolicyDecision] = []

    for step in workflow.steps {
      guard let node = nodePayloads[step.nodeId] else {
        continue
      }
      let stepDecision = evaluateStep(step: step, node: node, workflowPolicy: effective)
      decisions.append(contentsOf: stepDecision.decisions)
      denials.append(contentsOf: stepDecision.denials)
    }

    return LoopPolicyEvidence(
      declared: loop.policies,
      effective: effective,
      decisions: decisions,
      denials: denials
    )
  }

  public func evaluateStep(
    step: WorkflowStepRef,
    node: AgentNodePayload,
    workflowPolicy: LoopPolicyDeclaration?
  ) -> LoopPolicyStepDecision {
    guard let process = workflowPolicy?.process else {
      return LoopPolicyStepDecision(stepId: step.id, nodeId: step.nodeId, allowed: true)
    }

    var decisions: [LoopPolicyDecision] = []
    var denials: [LoopPolicyDecision] = []
    appendBackendDecision(step: step, node: node, process: process, decisions: &decisions, denials: &denials)
    appendWorkerModelDecision(step: step, node: node, process: process, decisions: &decisions, denials: &denials)
    appendNestedProcessDecisions(step: step, node: node, process: process, decisions: &decisions, denials: &denials)

    return LoopPolicyStepDecision(
      stepId: step.id,
      nodeId: step.nodeId,
      allowed: denials.isEmpty,
      decisions: decisions,
      denials: denials
    )
  }

  public func effectivePolicy(from declared: LoopPolicyDeclaration?) -> LoopPolicyDeclaration {
    var mutation = declared?.mutation ?? LoopMutationPolicyDeclaration()
    mutation.commit = mutation.commit ?? "deny"
    mutation.push = mutation.push ?? "deny"
    return LoopPolicyDeclaration(
      mutation: mutation,
      process: declared?.process,
      network: declared?.network,
      redaction: declared?.redaction
    )
  }

  public static func normalizedPolicyRelativePath(_ path: String) -> String? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !trimmed.isEmpty,
      !trimmed.hasPrefix("/"),
      !trimmed.contains(".."),
      trimmed.range(of: #"^[A-Za-z0-9._\-/]+$"#, options: .regularExpression) != nil
    else {
      return nil
    }
    return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private func baselineDecisions(for effective: LoopPolicyDeclaration) -> [LoopPolicyDecision] {
    var decisions: [LoopPolicyDecision] = []
    if let mutation = effective.mutation {
      decisions.append(decision("mutation.commit", mutation.commit ?? "deny", reason: "effective mutation policy"))
      decisions.append(decision("mutation.push", mutation.push ?? "deny", reason: "effective mutation policy"))
      for root in mutation.allowedWriteRoots {
        decisions.append(decision(
          "mutation.allowedWriteRoots",
          Self.normalizedPolicyRelativePath(root) == nil ? "deny" : "allow",
          reason: "allowed write root \(root)"
        ))
      }
      if let scratchRoot = mutation.scratchRoot {
        decisions.append(decision(
          "mutation.scratchRoot",
          Self.normalizedPolicyRelativePath(scratchRoot) == nil ? "deny" : "allow",
          reason: "scratch root \(scratchRoot)"
        ))
      }
    }
    if let process = effective.process {
      if let nestedRiela = process.nestedRiela {
        decisions.append(decision("process.nestedRiela", nestedRiela, reason: "declared nested Riela policy"))
      }
      if let nestedCodex = process.nestedCodex {
        decisions.append(decision("process.nestedCodex", nestedCodex, reason: "declared nested Codex policy"))
      }
    }
    return decisions
  }

  private func appendBackendDecision(
    step: WorkflowStepRef,
    node: AgentNodePayload,
    process: LoopProcessPolicyDeclaration,
    decisions: inout [LoopPolicyDecision],
    denials: inout [LoopPolicyDecision]
  ) {
    guard !process.allowedBackends.isEmpty else {
      return
    }
    let backend = policyBackend(for: node)
    let allowed = process.allowedBackends.contains(backend)
    let policyDecision = decision(
      "process.allowedBackends",
      allowed ? "allow" : "deny",
      reason: "step \(step.id) uses backend \(backend)"
    )
    decisions.append(policyDecision)
    if !allowed {
      denials.append(policyDecision)
    }
  }

  private func appendWorkerModelDecision(
    step: WorkflowStepRef,
    node: AgentNodePayload,
    process: LoopProcessPolicyDeclaration,
    decisions: inout [LoopPolicyDecision],
    denials: inout [LoopPolicyDecision]
  ) {
    guard step.role == .worker, let requiredModel = process.requiredWorkerModel, !requiredModel.isEmpty else {
      return
    }
    let allowed = node.model == requiredModel
    let policyDecision = decision(
      "process.requiredWorkerModel",
      allowed ? "allow" : "deny",
      reason: "step \(step.id) model \(node.model.isEmpty ? "<empty>" : node.model), required \(requiredModel)"
    )
    decisions.append(policyDecision)
    if !allowed {
      denials.append(policyDecision)
    }
  }

  private func appendNestedProcessDecisions(
    step: WorkflowStepRef,
    node: AgentNodePayload,
    process: LoopProcessPolicyDeclaration,
    decisions: inout [LoopPolicyDecision],
    denials: inout [LoopPolicyDecision]
  ) {
    appendNestedProcessDecision(
      policyName: "process.nestedRiela",
      configuredDecision: process.nestedRiela,
      executableNames: ["riela"],
      step: step,
      node: node,
      decisions: &decisions,
      denials: &denials
    )
    appendNestedProcessDecision(
      policyName: "process.nestedCodex",
      configuredDecision: process.nestedCodex,
      executableNames: ["codex"],
      step: step,
      node: node,
      decisions: &decisions,
      denials: &denials
    )
  }

  private func appendNestedProcessDecision(
    policyName: String,
    configuredDecision: String?,
    executableNames: [String],
    step: WorkflowStepRef,
    node: AgentNodePayload,
    decisions: inout [LoopPolicyDecision],
    denials: inout [LoopPolicyDecision]
  ) {
    guard let configuredDecision, commandLine(for: node) != nil else {
      return
    }
    let containsExecutable = commandLine(for: node).map { commandLine in
      executableNames.contains { executable in
        commandLineContainsExecutable(commandLine, executable: executable)
      }
    } ?? false
    let shouldDeny = configuredDecision == "deny" && containsExecutable
    let policyDecision = decision(
      policyName,
      shouldDeny ? "deny" : "declared-only",
      reason: shouldDeny
        ? "step \(step.id) command invokes denied nested process"
        : "step \(step.id) command boundary recorded; arbitrary shell text is not fully parsed"
    )
    decisions.append(policyDecision)
    if shouldDeny {
      denials.append(policyDecision)
    }
  }

  private func policyBackend(for node: AgentNodePayload) -> String {
    if let kind = workflowStdioNodeExecutionKind(for: node) {
      return kind.rawValue
    }
    return node.executionBackend?.rawValue ?? "unspecified"
  }

  private func commandLine(for node: AgentNodePayload) -> String? {
    if let command = node.command {
      return ([command.executable] + command.arguments).joined(separator: " ")
    }
    if let container = node.container {
      return container.command.joined(separator: " ")
    }
    return nil
  }

  private func commandLineContainsExecutable(_ commandLine: String, executable: String) -> Bool {
    let pattern = #"(^|[\s;&|()])"# + NSRegularExpression.escapedPattern(for: executable) + #"($|[\s;&|()])"#
    return commandLine.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
  }

  private func decision(_ policy: String, _ value: String, reason: String) -> LoopPolicyDecision {
    LoopPolicyDecision(
      id: "\(policy):\(value)",
      policy: policy,
      decision: value,
      reason: reason
    )
  }
}
