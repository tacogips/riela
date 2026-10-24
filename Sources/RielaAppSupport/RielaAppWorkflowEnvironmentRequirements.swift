import Foundation
import RielaCore

/// App-facing required-environment rows. The NAMES come from the same RielaCore
/// collector the CLI child (`riela events serve`) enforces
/// (`WorkflowEnvironmentRequirements.names`), so the managed-name set the App
/// sends over the private channel matches what the child checks. This type only
/// adds package descriptions and secret flags (`RielaAppEnvRequirement`).
///
/// Residual difference: the CLI also follows reachable called workflows, shared
/// node references and local add-on host requirements, which need the CLI's
/// bundle resolver. Those names are enforced by the child and reported through
/// its safe stderr code (`environment_required_missing`).
enum RielaAppWorkflowEnvironmentRequirements {
  static func requiredEnvironment(
    workflowDirectory: URL,
    packageRequirements: [RielaAppEnvRequirement] = []
  ) -> [RielaAppEnvRequirement] {
    var requirements = packageRequirements
    for name in workflowNames(workflowDirectory: workflowDirectory)
      where !requirements.contains(where: { $0.name == name }) {
      requirements.append(RielaAppEnvRequirement(name: name))
    }
    return requirements.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  /// The top-level workflow's required names as the CLI computes them: the
  /// authored workflow is validated with the same Core validator the bundle
  /// loader uses and node payloads are read from `nodeFile` references inside
  /// the workflow directory. An unreadable or invalid workflow (which the CLI
  /// also refuses to run) contributes no names.
  static func workflowNames(workflowDirectory: URL) -> [String] {
    guard let data = try? Data(contentsOf: workflowDirectory.appendingPathComponent("workflow.json")),
          let workflow = validateAuthoredWorkflowData(data).workflow else {
      return []
    }
    var payloads: [String: AgentNodePayload] = [:]
    for node in workflow.nodeRegistry {
      guard let nodeFile = node.nodeFile,
            let url = containedFile(nodeFile, in: workflowDirectory),
            let payloadData = try? Data(contentsOf: url),
            let payload = try? JSONDecoder().decode(AgentNodePayload.self, from: payloadData) else {
        continue
      }
      payloads[node.id] = payload
    }
    return (try? WorkflowEnvironmentRequirements.names(workflow: workflow, nodePayloads: payloads)) ?? []
  }

  private static func containedFile(_ relativePath: String, in directory: URL) -> URL? {
    let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
    let file = directory.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
    return file.path.hasPrefix(root + "/") ? file : nil
  }
}

/// One presence rule for required names, shared by the native window's
/// "Missing" column and the console projection, so loader-managed names are
/// not reported missing just because they are absent from the pre-loader
/// environment.
public enum RielaAppEnvironmentPresence {
  /// - A non-blank pre-loader value (process, `.env`, inline) is present.
  /// - After a successful load the published snapshot decides (`configuredNames`).
  /// - Before any load, a name an instance loader declares counts as present:
  ///   start runs the loader and fails with its own safe code if it is absent.
  /// - After a failed first load (no snapshot) only the pre-loader value counts.
  public static func isPresent(
    _ name: String,
    environment: [String: String],
    resolution: RuntimeEnvironmentConfiguration?,
    status: RuntimeEnvironmentStatus
  ) -> Bool {
    if environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
    switch status.readiness {
    case .ready: return status.configuredNames.contains(name)
    case .unprepared: return resolution?.sources.contains { $0.names.contains(name) } ?? false
    case .failed: return false
    }
  }

  public static func missingNames(
    _ names: [String],
    environment: [String: String],
    resolution: RuntimeEnvironmentConfiguration?,
    status: RuntimeEnvironmentStatus
  ) -> [String] {
    names.filter { !isPresent($0, environment: environment, resolution: resolution, status: status) }
  }
}
