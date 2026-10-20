import Foundation
import RielaAppSupport
import RielaCore

enum CLIRuntimeEnvironmentPreparation {
  static func prepare(path: String?, required: [String], base: [String: String],
                      workingDirectory: String) async throws -> [String: String] {
    let configuration: RuntimeEnvironmentConfiguration
    if let path {
      let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true))
      do {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw RuntimeEnvironmentError.invalidConfiguration }
        configuration = try JSONDecoder().decode(RuntimeEnvironmentConfiguration.self, from: data)
      } catch { throw RuntimeEnvironmentError.invalidConfiguration }
    } else {
      configuration = RuntimeEnvironmentConfiguration()
    }
    let names = try WorkflowEnvironmentRequirements.validated(required)
    let store = RuntimeEnvironmentSnapshotStore()
    let snapshot = try await store.prepare(scope: .init(profile: "cli", instanceIdentity: "invocation"),
      configuration: configuration, requiredNames: names, baseEnvironment: base)
    return snapshot.runtimeEnvironment()
  }

  static func required(bundle: ResolvedWorkflowBundle, resolution: WorkflowResolutionOptions,
                       resolver: any WorkflowBundleResolving) async throws -> [String] {
    let maps = try await reachableWorkflowMaps(bundle: bundle, resolution: resolution, resolver: resolver)
    var names: [String] = []
    for (id, workflow) in maps.workflows {
      names += try WorkflowEnvironmentRequirements.names(workflow: workflow, nodePayloads: maps.nodePayloads[id] ?? [:])
      for requirement in maps.nodeHostRequirements[id]?.values ?? [:].values {
        names += requirement.requiredEnvironment
      }
    }
    return try WorkflowEnvironmentRequirements.validated(names)
  }
}

func eventRequiredEnvironment(eventRoot: URL, target: String?, parsed: ParsedParityOptions) async throws -> [String] {
  let config = try EventLiveConfig.load(eventRoot: eventRoot)
  let enabled = Set(config.enabledSources(target: target).map(\.id))
  let names = Set(config.bindings.filter { $0.enabled && enabled.contains($0.sourceId) }.compactMap(\.workflowName))
  let resolver = FileSystemWorkflowBundleResolver()
  var required: [String] = []
  for name in names.sorted() {
    let resolution = WorkflowResolutionOptions(workflowName: name, scope: parsed.scope,
      workflowDefinitionDir: parsed.workflowDefinitionDir,
      workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath)
    let bundle = try resolver.resolve(resolution)
    required += try await CLIRuntimeEnvironmentPreparation.required(bundle: bundle, resolution: resolution, resolver: resolver)
  }
  return try WorkflowEnvironmentRequirements.validated(required)
}
