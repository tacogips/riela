import Foundation
import CoreFoundation

private let loopGateDecisionValues: Set<String> = ["accepted", "rejected", "needs_work", "skipped"]
private let loopPromptPolicyValues: Set<String> = ["allow", "deny", "prompt"]
private let loopNetworkModeValues: Set<String> = ["allow", "deny", "inherit-command"]
private let loopArtifactRootPolicyValues: Set<String> = ["runtime-owned"]

func validateTypedLoopMetadata(
  _ loop: WorkflowLoopMetadata?,
  stepIds: Set<String>,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let loop else {
    return
  }

  if let artifactRootPolicy = loop.evidence?.artifactRootPolicy {
    validateAllowedValue(
      artifactRootPolicy,
      allowed: loopArtifactRootPolicyValues,
      path: "workflow.loop.evidence.artifactRootPolicy",
      diagnostics: &diagnostics
    )
  }

  if let mutation = loop.policies?.mutation {
    for (index, root) in mutation.allowedWriteRoots.enumerated() {
      validateLoopWorkflowRelativePath(
        root,
        fieldName: "allowedWriteRoots",
        path: "workflow.loop.policies.mutation.allowedWriteRoots[\(index)]",
        diagnostics: &diagnostics
      )
    }
    if let scratchRoot = mutation.scratchRoot {
      validateLoopWorkflowRelativePath(
        scratchRoot,
        fieldName: "scratchRoot",
        path: "workflow.loop.policies.mutation.scratchRoot",
        diagnostics: &diagnostics
      )
    }
    if let commit = mutation.commit {
      validateAllowedValue(
        commit,
        allowed: loopPromptPolicyValues,
        path: "workflow.loop.policies.mutation.commit",
        diagnostics: &diagnostics
      )
    }
    if let push = mutation.push {
      validateAllowedValue(
        push,
        allowed: loopPromptPolicyValues,
        path: "workflow.loop.policies.mutation.push",
        diagnostics: &diagnostics
      )
    }
  }

  if let process = loop.policies?.process {
    if let nestedRiela = process.nestedRiela {
      validateAllowedValue(
        nestedRiela,
        allowed: loopPromptPolicyValues,
        path: "workflow.loop.policies.process.nestedRiela",
        diagnostics: &diagnostics
      )
    }
    if let nestedCodex = process.nestedCodex {
      validateAllowedValue(
        nestedCodex,
        allowed: loopPromptPolicyValues,
        path: "workflow.loop.policies.process.nestedCodex",
        diagnostics: &diagnostics
      )
    }
  }

  if let networkMode = loop.policies?.network?.mode {
    validateAllowedValue(
      networkMode,
      allowed: loopNetworkModeValues,
      path: "workflow.loop.policies.network.mode",
      diagnostics: &diagnostics
    )
  }

  var seenGateIds: Set<String> = []
  for (index, gate) in loop.gates.enumerated() {
    let path = "workflow.loop.gates[\(index)]"
    validateNonEmptyLoopString(gate.id, path: "\(path).id", diagnostics: &diagnostics)
    if !gate.id.isEmpty {
      if seenGateIds.contains(gate.id) {
        diagnostics.append(loopValidationError("\(path).id", "must be unique across workflow.loop.gates[]"))
      }
      seenGateIds.insert(gate.id)
    }
    validateNonEmptyLoopString(gate.stepId, path: "\(path).stepId", diagnostics: &diagnostics)
    if !gate.stepId.isEmpty && !stepIds.contains(gate.stepId) {
      diagnostics.append(loopValidationError("\(path).stepId", "must reference workflow.steps[] entry '\(gate.stepId)'"))
    }
    if let maxHighFindings = gate.acceptWhen.maxHighFindings, maxHighFindings < 0 {
      diagnostics.append(loopValidationError("\(path).acceptWhen.maxHighFindings", "must be a non-negative integer"))
    }
    if let maxMediumFindings = gate.acceptWhen.maxMediumFindings, maxMediumFindings < 0 {
      diagnostics.append(loopValidationError("\(path).acceptWhen.maxMediumFindings", "must be a non-negative integer"))
    }
  }

  if let pathPattern = loop.implementationPlan?.pathPattern {
    validateLoopWorkflowRelativePath(
      pathPattern,
      fieldName: "pathPattern",
      path: "workflow.loop.implementationPlan.pathPattern",
      diagnostics: &diagnostics
    )
  }
}

func validateTypedStepLoop(
  _ loop: WorkflowStepLoopMetadata?,
  path: String,
  gateIds: Set<String>,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let loop, let gateId = loop.gateId else {
    return
  }
  if gateId.isEmpty {
    diagnostics.append(loopValidationError("\(path).gateId", "must be a non-empty string"))
  } else if !gateIds.isEmpty && !gateIds.contains(gateId) {
    diagnostics.append(loopValidationError("\(path).gateId", "must reference workflow.loop.gates[] entry '\(gateId)'"))
  }
}

func validateRawLoopMetadata(
  _ raw: Any?,
  stepIds: Set<String>,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let raw else {
    return
  }
  guard let loop = raw as? [String: Any] else {
    diagnostics.append(loopValidationError("workflow.loop", "must be an object when provided"))
    return
  }

  validateRawLoopEvidence(loop["evidence"], diagnostics: &diagnostics)
  validateRawLoopPolicies(loop["policies"], diagnostics: &diagnostics)
  validateRawLoopGates(loop["gates"], stepIds: stepIds, diagnostics: &diagnostics)
  validateRawLoopImplementationPlan(loop["implementationPlan"], diagnostics: &diagnostics)
}

func rawLoopGateIds(_ raw: Any?) -> Set<String> {
  guard let loop = raw as? [String: Any], let gates = loop["gates"] as? [Any] else {
    return []
  }
  return Set(gates.compactMap { gate -> String? in
    guard let gate = gate as? [String: Any], let id = gate["id"] as? String, !id.isEmpty else {
      return nil
    }
    return id
  })
}

func validateRawStepLoop(
  _ raw: Any?,
  path: String,
  gateIds: Set<String>,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let raw else {
    return
  }
  guard let loop = raw as? [String: Any] else {
    diagnostics.append(loopValidationError(path, "must be an object when provided"))
    return
  }
  guard let gateId = loop["gateId"] else {
    return
  }
  validateNonEmptyLoopString(gateId, path: "\(path).gateId", diagnostics: &diagnostics)
  if let gateId = gateId as? String, !gateId.isEmpty, !gateIds.isEmpty, !gateIds.contains(gateId) {
    diagnostics.append(loopValidationError("\(path).gateId", "must reference workflow.loop.gates[] entry '\(gateId)'"))
  }
}

private func validateRawLoopEvidence(_ raw: Any?, diagnostics: inout [WorkflowValidationDiagnostic]) {
  guard let raw else {
    return
  }
  guard let evidence = raw as? [String: Any] else {
    diagnostics.append(loopValidationError("workflow.loop.evidence", "must be an object when provided"))
    return
  }
  validateAllowedRawString(
    evidence["artifactRootPolicy"],
    allowed: loopArtifactRootPolicyValues,
    path: "workflow.loop.evidence.artifactRootPolicy",
    diagnostics: &diagnostics
  )
}

private func validateRawLoopPolicies(_ raw: Any?, diagnostics: inout [WorkflowValidationDiagnostic]) {
  guard let raw else {
    return
  }
  guard let policies = raw as? [String: Any] else {
    diagnostics.append(loopValidationError("workflow.loop.policies", "must be an object when provided"))
    return
  }

  validateRawLoopMutationPolicy(policies["mutation"], diagnostics: &diagnostics)
  validateRawLoopProcessPolicy(policies["process"], diagnostics: &diagnostics)

  if let rawNetwork = policies["network"] {
    guard let network = rawNetwork as? [String: Any] else {
      diagnostics.append(loopValidationError("workflow.loop.policies.network", "must be an object when provided"))
      return
    }
    validateAllowedRawString(
      network["mode"],
      allowed: loopNetworkModeValues,
      path: "workflow.loop.policies.network.mode",
      diagnostics: &diagnostics
    )
  }
}

private func validateRawLoopMutationPolicy(_ raw: Any?, diagnostics: inout [WorkflowValidationDiagnostic]) {
  guard let raw else {
    return
  }
  guard let mutation = raw as? [String: Any] else {
    diagnostics.append(loopValidationError("workflow.loop.policies.mutation", "must be an object when provided"))
    return
  }

  if let rawAllowedWriteRoots = mutation["allowedWriteRoots"] {
    guard let roots = rawAllowedWriteRoots as? [Any] else {
      diagnostics.append(loopValidationError("workflow.loop.policies.mutation.allowedWriteRoots", "must be an array when provided"))
      return
    }
    for (index, root) in roots.enumerated() {
      validateLoopWorkflowRelativePath(
        root,
        fieldName: "allowedWriteRoots",
        path: "workflow.loop.policies.mutation.allowedWriteRoots[\(index)]",
        diagnostics: &diagnostics
      )
    }
  }

  if let scratchRoot = mutation["scratchRoot"] {
    validateLoopWorkflowRelativePath(
      scratchRoot,
      fieldName: "scratchRoot",
      path: "workflow.loop.policies.mutation.scratchRoot",
      diagnostics: &diagnostics
    )
  }
  validateAllowedRawString(
    mutation["commit"],
    allowed: loopPromptPolicyValues,
    path: "workflow.loop.policies.mutation.commit",
    diagnostics: &diagnostics
  )
  validateAllowedRawString(
    mutation["push"],
    allowed: loopPromptPolicyValues,
    path: "workflow.loop.policies.mutation.push",
    diagnostics: &diagnostics
  )
}

private func validateRawLoopProcessPolicy(_ raw: Any?, diagnostics: inout [WorkflowValidationDiagnostic]) {
  guard let raw else {
    return
  }
  guard let process = raw as? [String: Any] else {
    diagnostics.append(loopValidationError("workflow.loop.policies.process", "must be an object when provided"))
    return
  }
  validateAllowedRawString(
    process["nestedRiela"],
    allowed: loopPromptPolicyValues,
    path: "workflow.loop.policies.process.nestedRiela",
    diagnostics: &diagnostics
  )
  validateAllowedRawString(
    process["nestedCodex"],
    allowed: loopPromptPolicyValues,
    path: "workflow.loop.policies.process.nestedCodex",
    diagnostics: &diagnostics
  )
}

private func validateRawLoopGates(
  _ raw: Any?,
  stepIds: Set<String>,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let raw else {
    return
  }
  guard let gates = raw as? [Any] else {
    diagnostics.append(loopValidationError("workflow.loop.gates", "must be an array when provided"))
    return
  }

  var seenGateIds: Set<String> = []
  for (index, rawGate) in gates.enumerated() {
    let path = "workflow.loop.gates[\(index)]"
    guard let gate = rawGate as? [String: Any] else {
      diagnostics.append(loopValidationError(path, "must be an object"))
      continue
    }
    validateNonEmptyLoopString(gate["id"], path: "\(path).id", diagnostics: &diagnostics)
    if let id = gate["id"] as? String, !id.isEmpty {
      if seenGateIds.contains(id) {
        diagnostics.append(loopValidationError("\(path).id", "must be unique across workflow.loop.gates[]"))
      }
      seenGateIds.insert(id)
    }
    validateNonEmptyLoopString(gate["stepId"], path: "\(path).stepId", diagnostics: &diagnostics)
    if let stepId = gate["stepId"] as? String, !stepId.isEmpty, !stepIds.contains(stepId) {
      diagnostics.append(loopValidationError("\(path).stepId", "must reference workflow.steps[] entry '\(stepId)'"))
    }
    validateRawLoopGateAcceptance(gate["acceptWhen"], path: "\(path).acceptWhen", diagnostics: &diagnostics)
  }
}

private func validateRawLoopGateAcceptance(
  _ raw: Any?,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let raw else {
    return
  }
  guard let acceptWhen = raw as? [String: Any] else {
    diagnostics.append(loopValidationError(path, "must be an object when provided"))
    return
  }
  validateAllowedRawString(
    acceptWhen["decision"],
    allowed: loopGateDecisionValues,
    path: "\(path).decision",
    diagnostics: &diagnostics
  )
  if let maxHighFindings = acceptWhen["maxHighFindings"] {
    validateNonNegativeInteger(maxHighFindings, path: "\(path).maxHighFindings", diagnostics: &diagnostics)
  }
  if let maxMediumFindings = acceptWhen["maxMediumFindings"] {
    validateNonNegativeInteger(maxMediumFindings, path: "\(path).maxMediumFindings", diagnostics: &diagnostics)
  }
}

private func validateRawLoopImplementationPlan(_ raw: Any?, diagnostics: inout [WorkflowValidationDiagnostic]) {
  guard let raw else {
    return
  }
  guard let implementationPlan = raw as? [String: Any] else {
    diagnostics.append(loopValidationError("workflow.loop.implementationPlan", "must be an object when provided"))
    return
  }
  if let pathPattern = implementationPlan["pathPattern"] {
    validateLoopWorkflowRelativePath(
      pathPattern,
      fieldName: "pathPattern",
      path: "workflow.loop.implementationPlan.pathPattern",
      diagnostics: &diagnostics
    )
  }
}

private func validateAllowedValue(
  _ value: String,
  allowed: Set<String>,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  if !allowed.contains(value) {
    diagnostics.append(loopValidationError(path, "must be one of \(allowed.sorted().joined(separator: ", "))"))
  }
}

private func validateAllowedRawString(
  _ value: Any?,
  allowed: Set<String>,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let value else {
    return
  }
  guard let string = value as? String else {
    diagnostics.append(loopValidationError(path, "must be one of \(allowed.sorted().joined(separator: ", "))"))
    return
  }
  validateAllowedValue(string, allowed: allowed, path: path, diagnostics: &diagnostics)
}

private func validateNonNegativeInteger(
  _ value: Any?,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let number = value as? NSNumber,
    !isLoopValidationBooleanNumber(number),
    floor(number.doubleValue) == number.doubleValue,
    number.intValue >= 0
  else {
    diagnostics.append(loopValidationError(path, "must be a non-negative integer"))
    return
  }
}

private func validateNonEmptyLoopString(
  _ value: Any?,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let string = value as? String, !string.isEmpty else {
    diagnostics.append(loopValidationError(path, "must be a non-empty string"))
    return
  }
}

private func validateLoopWorkflowRelativePath(
  _ value: Any?,
  fieldName: String,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let string = value as? String, !string.isEmpty else {
    diagnostics.append(loopValidationError(path, "must be a non-empty string"))
    return
  }
  guard isSafeLoopWorkflowRelativePath(string) else {
    diagnostics.append(loopValidationError(path, "\(fieldName) '\(string)' must be a workflow-relative path without '.' or '..' segments"))
    return
  }
}

private func isSafeLoopWorkflowRelativePath(_ value: String) -> Bool {
  if value.isEmpty || value.hasPrefix("/") || value.hasPrefix("\\") || matchesLoopValidation(value, pattern: #"^[A-Za-z]:[\\/]"#) {
    return false
  }
  let segments = value.split { character in
    character == "/" || character == "\\"
  }
  if segments.isEmpty {
    return false
  }
  return !segments.contains { segment in
    segment == "." || segment == ".."
  }
}

private func isLoopValidationBooleanNumber(_ number: NSNumber) -> Bool {
  CFGetTypeID(number) == CFBooleanGetTypeID()
}

private func matchesLoopValidation(_ value: String, pattern: String) -> Bool {
  value.range(of: pattern, options: .regularExpression) != nil
}

private func loopValidationError(_ path: String, _ message: String) -> WorkflowValidationDiagnostic {
  WorkflowValidationDiagnostic(severity: .error, path: path, message: message)
}
