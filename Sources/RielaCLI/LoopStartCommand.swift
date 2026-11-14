import Foundation
import RielaCore

public struct LoopGatePanelEntry: Codable, Equatable, Sendable {
  public var gateId: String
  public var stepId: String
  public var required: Bool

  public init(gateId: String, stepId: String, required: Bool) {
    self.gateId = gateId
    self.stepId = stepId
    self.required = required
  }
}

/// The pre-run policy panel `loop start` surfaces before delegating to the
/// `workflow run` execution path. Built from authored loop metadata plus the
/// `LoopPolicyEvaluator` preflight's effective policy; contains policy names
/// and declared bounds only — never secret or environment values.
public struct LoopPolicyPanel: Codable, Equatable, Sendable {
  public var workflowId: String
  public var loopKind: String?
  public var required: Bool
  public var mutationRoots: [String]
  public var scratchRoot: String?
  public var commit: String
  public var push: String
  public var nestedProcessPolicy: [String: String]
  public var allowedBackends: [String]
  public var requiredWorkerModel: String?
  public var gates: [LoopGatePanelEntry]
  public var budget: LoopBudgetDeclaration?
  public var evidenceRequiredSections: [String]

  public init(
    workflowId: String,
    loopKind: String? = nil,
    required: Bool,
    mutationRoots: [String] = [],
    scratchRoot: String? = nil,
    commit: String,
    push: String,
    nestedProcessPolicy: [String: String] = [:],
    allowedBackends: [String] = [],
    requiredWorkerModel: String? = nil,
    gates: [LoopGatePanelEntry] = [],
    budget: LoopBudgetDeclaration? = nil,
    evidenceRequiredSections: [String] = []
  ) {
    self.workflowId = workflowId
    self.loopKind = loopKind
    self.required = required
    self.mutationRoots = mutationRoots
    self.scratchRoot = scratchRoot
    self.commit = commit
    self.push = push
    self.nestedProcessPolicy = nestedProcessPolicy
    self.allowedBackends = allowedBackends
    self.requiredWorkerModel = requiredWorkerModel
    self.gates = gates
    self.budget = budget
    self.evidenceRequiredSections = evidenceRequiredSections
  }
}

/// The CLI-emitted `loop_policy` JSON/JSONL record. This is not a runner
/// event: `loop start` prints it ahead of the delegated run's output so it
/// precedes `session_started` in the stream.
struct LoopPolicyRecord: Codable, Equatable, Sendable {
  var type = "loop_policy"
  var panel: LoopPolicyPanel
}

/// `riela loop start <workflow> [--var k=v ...] [workflow-run options]`.
/// Shows the loop policy panel, then delegates to the existing `workflow run`
/// execution path unchanged (same progress records, persistence, and evidence
/// projection). Invocation is consent — there is no interactive confirmation
/// in any output mode.
public struct LoopStartCommand: Sendable {
  public var resolver: any WorkflowBundleResolving
  public var runCommand: WorkflowRunCommand
  public var policyEvaluator: any LoopPolicyEvaluating

  public init(
    resolver: any WorkflowBundleResolving = FileSystemWorkflowBundleResolver(),
    runCommand: WorkflowRunCommand = WorkflowRunCommand(),
    policyEvaluator: any LoopPolicyEvaluating = DefaultLoopPolicyEvaluator()
  ) {
    self.resolver = resolver
    self.runCommand = runCommand
    self.policyEvaluator = policyEvaluator
  }

  public func run(_ options: CLICommandOptions) async -> CLICommandResult {
    guard let workflowName = options.target, !workflowName.isEmpty else {
      return CLICommandResult(exitCode: .usage, stderr: "loop start requires a workflow id")
    }
    do {
      let runOptions = try Self.workflowRunOptions(workflowName: workflowName, tokens: options.arguments)
      let resolution = runOptions.resolution ?? WorkflowResolutionOptions(
        workflowName: runOptions.target,
        workingDirectory: runOptions.workingDirectory
      )
      let bundle = try resolver.resolve(resolution)
      guard let loop = bundle.workflow.loop else {
        return CLICommandResult(
          exitCode: .usage,
          stderr: "workflow '\(bundle.workflow.workflowId)' declares no loop metadata; run it with `riela workflow run \(workflowName)` instead"
        )
      }
      let panel = Self.policyPanel(
        workflow: bundle.workflow,
        loop: loop,
        nodePayloads: bundle.nodePayloads,
        policyEvaluator: policyEvaluator
      )
      let delegated = await runCommand.run(runOptions)
      let prefix: String
      switch runOptions.output {
      case .json, .jsonl:
        prefix = ((try? jsonString(LoopPolicyRecord(panel: panel))) ?? #"{"type":"loop_policy"}"#)
          .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
      case .text, .table:
        prefix = Self.panelText(panel)
      }
      return CLICommandResult(
        exitCode: delegated.exitCode,
        stdout: prefix + delegated.stdout,
        stderr: delegated.stderr
      )
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  /// Splits `--var k=v` pairs out of the token stream (they are a `loop
  /// start` convenience, not a `workflow run` option), rejects the reserved
  /// `--isolate` flag, and parses the remainder through the real `workflow
  /// run` argument parser so behavior stays identical to `workflow run`.
  static func workflowRunOptions(workflowName: String, tokens: [String]) throws -> WorkflowRunOptions {
    var variables: [String: JSONValue] = [:]
    var passthrough: [String] = []
    var index = 0
    while index < tokens.count {
      let token = tokens[index]
      if token == "--isolate" {
        throw CLIUsageError("loop start --isolate is not yet supported; worktree isolation lands in a later phase (LA6)")
      }
      if token == "--var" {
        guard index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") else {
          throw CLIUsageError("--var requires a k=v value")
        }
        let pair = tokens[index + 1]
        guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else {
          throw CLIUsageError("--var requires a k=v value; got '\(pair)'")
        }
        variables[String(pair[pair.startIndex..<separator])] = .string(String(pair[pair.index(after: separator)...]))
        index += 2
        continue
      }
      passthrough.append(token)
      index += 1
    }
    if !variables.isEmpty {
      guard !passthrough.contains("--variables") else {
        throw CLIUsageError("loop start cannot combine --var with --variables; pass one form")
      }
      passthrough.append("--variables")
      passthrough.append(try jsonString(variables).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let parsed = try RielaArgumentParser().parse(["workflow", "run", workflowName] + passthrough)
    guard case let .workflow(.run(runOptions)) = parsed else {
      throw CLIUsageError("loop start could not derive workflow run options for '\(workflowName)'")
    }
    return runOptions
  }

  static func policyPanel(
    workflow: WorkflowDefinition,
    loop: WorkflowLoopMetadata,
    nodePayloads: [String: AgentNodePayload],
    policyEvaluator: any LoopPolicyEvaluating = DefaultLoopPolicyEvaluator()
  ) -> LoopPolicyPanel {
    let preflight = policyEvaluator.preflight(workflow: workflow, nodePayloads: nodePayloads)
    let effective = preflight.effective ?? loop.policies
    let mutation = effective?.mutation
    let process = effective?.process
    return LoopPolicyPanel(
      workflowId: workflow.workflowId,
      loopKind: loop.kind,
      required: loop.required,
      mutationRoots: mutation?.allowedWriteRoots ?? [],
      scratchRoot: mutation?.scratchRoot,
      commit: mutation?.commit ?? "not-declared",
      push: mutation?.push ?? "not-declared",
      nestedProcessPolicy: [
        "riela": process?.nestedRiela ?? "not-declared",
        "codex": process?.nestedCodex ?? "not-declared"
      ],
      allowedBackends: process?.allowedBackends ?? [],
      requiredWorkerModel: process?.requiredWorkerModel,
      gates: loop.gates.map { LoopGatePanelEntry(gateId: $0.id, stepId: $0.stepId, required: $0.required) },
      budget: loop.budget,
      evidenceRequiredSections: loop.evidence?.requiredSections ?? []
    )
  }

  static func panelText(_ panel: LoopPolicyPanel) -> String {
    var lines = [
      "loop policy: \(panel.workflowId)",
      "  kind: \(panel.loopKind ?? "not-declared")  required: \(panel.required)",
      "  mutation roots: \(panel.mutationRoots.isEmpty ? "not-declared" : panel.mutationRoots.joined(separator: ", "))",
      "  scratch root: \(panel.scratchRoot ?? "not-declared")",
      "  commit: \(panel.commit)  push: \(panel.push)",
      "  nested process: riela=\(panel.nestedProcessPolicy["riela"] ?? "not-declared") codex=\(panel.nestedProcessPolicy["codex"] ?? "not-declared")",
      "  allowed backends: \(panel.allowedBackends.isEmpty ? "not-declared" : panel.allowedBackends.joined(separator: ", "))",
      "  required worker model: \(panel.requiredWorkerModel ?? "not-declared")"
    ]
    if panel.gates.isEmpty {
      lines.append("  gates: none")
    } else {
      lines.append("  gates:")
      for gate in panel.gates {
        lines.append("    \(gate.gateId) (step \(gate.stepId), \(gate.required ? "required" : "optional"))")
      }
    }
    if let budget = panel.budget {
      let bounds = [
        budget.maxTotalTokens.map { "maxTotalTokens=\($0)" },
        budget.maxWallClockMs.map { "maxWallClockMs=\($0)" },
        budget.maxSessionAttempts.map { "maxSessionAttempts=\($0)" }
      ].compactMap { $0 }.joined(separator: " ")
      lines.append("  budget: \(bounds) onExceeded=\(budget.onExceeded)")
    } else {
      lines.append("  budget: not-declared")
    }
    lines.append(
      "  evidence sections: \(panel.evidenceRequiredSections.isEmpty ? "not-declared" : panel.evidenceRequiredSections.joined(separator: ", "))"
    )
    return lines.joined(separator: "\n") + "\n"
  }
}
