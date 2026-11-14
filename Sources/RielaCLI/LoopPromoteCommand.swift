import Foundation
import RielaAddons
import RielaCore

public struct LoopPromoteIssue: Codable, Equatable, Sendable {
  public var code: String
  public var path: String
  public var message: String
  /// `enforced` when the check gates promotion today (`loop.required` for
  /// workflow checks, `loop.promotionReady` for package-manifest checks);
  /// `advisory` otherwise. Advisory issues never flip `ready`.
  public var level: String

  public init(code: String, path: String, message: String, level: String) {
    self.code = code
    self.path = path
    self.message = message
    self.level = level
  }
}

public struct LoopPromoteResult: Codable, Equatable, Sendable {
  public var workflowId: String
  public var ready: Bool
  public var issues: [LoopPromoteIssue]

  public init(workflowId: String, ready: Bool, issues: [LoopPromoteIssue]) {
    self.workflowId = workflowId
    self.ready = ready
    self.issues = issues
  }
}

/// `riela loop promote <workflow>` — read-only promotion-readiness report.
/// Reuses the packaged loop-readiness checks plus package-manifest promotion
/// artifact validation, but in advisory mode: every check is evaluated
/// regardless of the `loop.required`/`promotionReady` gates that make
/// optional-loop workflows trivially "ready", and each issue is labeled
/// `enforced` or `advisory`. `ready` is computed over enforced issues only.
public struct LoopPromoteCommand: Sendable {
  public var resolver: any WorkflowBundleResolving

  public init(resolver: any WorkflowBundleResolving = FileSystemWorkflowBundleResolver()) {
    self.resolver = resolver
  }

  public func run(_ options: CLICommandOptions) async -> CLICommandResult {
    guard let workflowName = options.target, !workflowName.isEmpty else {
      return CLICommandResult(exitCode: .usage, stderr: "loop promote requires a workflow id")
    }
    do {
      let parsed = try ParsedWorkflowOptions(options.arguments)
      let resolution = WorkflowResolutionOptions(
        workflowName: workflowName,
        scope: parsed.scope,
        workflowDefinitionDir: parsed.workflowDefinitionDir,
        workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
      )
      let bundle = try resolver.resolve(resolution)
      let result = Self.promotionReadiness(bundle: bundle)
      return try render(result, output: options.output)
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      if options.output.isStructured {
        let payload = LoopCommandFailureResult(
          sessionId: workflowName,
          command: "promote",
          error: "\(error)",
          exitCode: CLIExitCode.failure.rawValue
        )
        return CLICommandResult(exitCode: .failure, stdout: (try? jsonString(payload)) ?? "")
      }
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  /// Pure readiness evaluation over a resolved bundle; performs no mutation.
  static func promotionReadiness(bundle: ResolvedWorkflowBundle) -> LoopPromoteResult {
    var issues: [LoopPromoteIssue] = []
    let loop = bundle.workflow.loop
    let workflowLevel = loop?.required == true ? "enforced" : "advisory"
    if loop == nil {
      issues.append(LoopPromoteIssue(
        code: "LOOP_READINESS",
        path: "workflow.loop",
        message: "workflow declares no loop metadata",
        level: "advisory"
      ))
    }
    let evaluated = loop ?? WorkflowLoopMetadata(required: false, gates: [])
    issues += packageLoopReadinessIssues(evaluating: evaluated).map {
      LoopPromoteIssue(code: $0.code, path: $0.path, message: $0.message, level: workflowLevel)
    }

    if let manifest = bundle.packageManifest {
      let packageLevel = manifest.loop?.promotionReady == true ? "enforced" : "advisory"
      var manifestIssues = WorkflowPackageManifestValidator.loopPromotionReadinessIssues(manifest.loop)
      if let packageDirectory = bundle.packageDirectory {
        manifestIssues += WorkflowPackageManifestValidator.loopPromotionArtifactIssues(
          manifest.loop,
          packageRoot: URL(fileURLWithPath: packageDirectory, isDirectory: true)
        )
      }
      issues += manifestIssues.map {
        LoopPromoteIssue(code: $0.code, path: $0.path, message: $0.message, level: packageLevel)
      }
    }

    return LoopPromoteResult(
      workflowId: bundle.workflow.workflowId,
      ready: !issues.contains { $0.level == "enforced" },
      issues: issues
    )
  }

  private func render(_ result: LoopPromoteResult, output: WorkflowOutputFormat) throws -> CLICommandResult {
    switch output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: .success, stdout: try jsonString(result) + "\n")
    case .text, .table:
      var lines = [
        "workflow: \(result.workflowId)",
        "ready: \(result.ready)"
      ]
      if result.issues.isEmpty {
        lines.append("issues: none")
      } else {
        lines.append("issues:")
        for issue in result.issues {
          lines.append("  [\(issue.level)] \(issue.path): \(issue.message)")
        }
      }
      return CLICommandResult(exitCode: .success, stdout: lines.joined(separator: "\n") + "\n")
    }
  }
}
