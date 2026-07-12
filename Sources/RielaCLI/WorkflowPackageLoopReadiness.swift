import RielaAddons
import RielaCore

func packageLoopReadinessIssues(for loop: WorkflowLoopMetadata?) -> [WorkflowPackageValidationIssue] {
  guard let loop, loop.required else {
    return []
  }
  return packageLoopReadinessIssues(evaluating: loop)
}

/// Ungated variant for `loop promote`'s advisory mode: evaluates every
/// readiness check regardless of `loop.required` so optional-loop workflows
/// get a truthful report instead of a trivially empty one. The caller labels
/// the resulting issues enforced/advisory.
func packageLoopReadinessIssues(evaluating loop: WorkflowLoopMetadata) -> [WorkflowPackageValidationIssue] {
  var issues: [WorkflowPackageValidationIssue] = []
  if loop.evidence?.required != true {
    issues.append(packageLoopReadinessIssue("workflow.loop.evidence.required", "required loop packages must require evidence"))
  }
  if loop.evidence?.artifactRootPolicy != "runtime-owned" {
    issues.append(packageLoopReadinessIssue("workflow.loop.evidence.artifactRootPolicy", "required loop packages must use runtime-owned evidence"))
  }
  if loop.gates.isEmpty {
    issues.append(packageLoopReadinessIssue("workflow.loop.gates", "required loop packages must declare at least one review gate"))
  }
  if loop.implementationPlan?.required != true {
    issues.append(packageLoopReadinessIssue("workflow.loop.implementationPlan.required", "required loop packages must require an implementation plan"))
  }
  if loop.implementationPlan?.pathPattern?.isEmpty != false {
    issues.append(packageLoopReadinessIssue("workflow.loop.implementationPlan.pathPattern", "required loop packages must declare an implementation plan path pattern"))
  }
  appendMutationPolicyReadinessIssues(loop.policies?.mutation, into: &issues)
  appendProcessPolicyReadinessIssues(loop.policies?.process, into: &issues)
  return issues
}

private func appendMutationPolicyReadinessIssues(
  _ mutation: LoopMutationPolicyDeclaration?,
  into issues: inout [WorkflowPackageValidationIssue]
) {
  guard let mutation else {
    issues.append(packageLoopReadinessIssue("workflow.loop.policies.mutation", "required loop packages must declare mutation policy"))
    return
  }
  if mutation.allowedWriteRoots.isEmpty {
    issues.append(packageLoopReadinessIssue("workflow.loop.policies.mutation.allowedWriteRoots", "required loop packages must declare allowed write roots"))
  }
  if mutation.scratchRoot?.isEmpty != false {
    issues.append(packageLoopReadinessIssue("workflow.loop.policies.mutation.scratchRoot", "required loop packages must declare a scratch root"))
  }
  if mutation.commit?.isEmpty != false {
    issues.append(packageLoopReadinessIssue("workflow.loop.policies.mutation.commit", "required loop packages must declare commit policy"))
  }
  if mutation.push?.isEmpty != false {
    issues.append(packageLoopReadinessIssue("workflow.loop.policies.mutation.push", "required loop packages must declare push policy"))
  }
}

private func appendProcessPolicyReadinessIssues(
  _ process: LoopProcessPolicyDeclaration?,
  into issues: inout [WorkflowPackageValidationIssue]
) {
  guard let process else {
    issues.append(packageLoopReadinessIssue("workflow.loop.policies.process", "required loop packages must declare process policy"))
    return
  }
  if process.nestedRiela?.isEmpty != false {
    issues.append(packageLoopReadinessIssue("workflow.loop.policies.process.nestedRiela", "required loop packages must declare nested Riela policy"))
  }
  if process.nestedCodex?.isEmpty != false {
    issues.append(packageLoopReadinessIssue("workflow.loop.policies.process.nestedCodex", "required loop packages must declare nested Codex policy"))
  }
  if process.allowedBackends.isEmpty {
    issues.append(packageLoopReadinessIssue("workflow.loop.policies.process.allowedBackends", "required loop packages must declare allowed backends"))
  }
}

private func packageLoopReadinessIssue(_ path: String, _ message: String) -> WorkflowPackageValidationIssue {
  WorkflowPackageValidationIssue(code: "LOOP_READINESS", path: path, message: message)
}

/// Portability warning (design S12): `command` notification channels
/// reference machine-local scripts, so packaged workflows are flagged;
/// webhook channels stay portable by construction (env-name indirection).
/// Advisory only — it never gates package validity.
func packageLoopNotificationWarnings(for loop: WorkflowLoopMetadata?) -> [WorkflowPackageValidationIssue] {
  guard let channels = loop?.notifications?.channels else {
    return []
  }
  return channels.enumerated().compactMap { index, channel in
    guard channel.type == "command" else {
      return nil
    }
    return WorkflowPackageValidationIssue(
      code: "LOOP_NOTIFICATION_PORTABILITY",
      path: "workflow.loop.notifications.channels[\(index)]",
      message: "command notification channels are not portable in packaged workflows; prefer webhook channels"
    )
  }
}
