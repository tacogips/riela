import Foundation
import RielaAdapters
import RielaAddons
import RielaCore
import RielaServer

struct DistributedWorkerCommand: Sendable {
  struct Workspace: Decodable, Sendable {
      var path: String
      var controllerPath: String?
      var allowedAddons: Set<String>?
      var allowedEnvironment: Set<String>?
    }
  struct Configuration: Decodable, Sendable {
    var controllerURL: URL
    var tokenEnvironment: String?
    var tokenFile: String?
    var capacity: Int
    var allowInsecureHTTP: Bool?
    var workspaces: [String: Workspace]
    var backends: [String: BackendCapabilityDeclaration]?

    func registrationCapabilityMetadata(
      relativeTo configURL: URL,
      inheritedEnvironment: [String: String]
    ) async throws -> DistributedWorkerCapabilityMetadata {
      var workspaceEnvironments: [[String: Bool]] = []
      var workspaceAddons: [[String: Bool]] = []
      for workspaceName in workspaces.keys.sorted() {
        guard let workspace = workspaces[workspaceName] else { continue }
        let workspaceRoot = workspace.path.hasPrefix("/") ? URL(fileURLWithPath: workspace.path)
          : configURL.deletingLastPathComponent().appendingPathComponent(workspace.path)
        let executionEnvironment = try executionEnvironment(for: workspace, from: inheritedEnvironment)
        let candidateEnvironmentNames = Set(executionEnvironment.keys).union(workspace.allowedEnvironment ?? [])
        var environmentPresence: [String: Bool] = [:]
        for name in candidateEnvironmentNames where name != tokenEnvironment {
          environmentPresence[name] = executionEnvironment[name]?.isEmpty == false
        }
        workspaceEnvironments.append(environmentPresence)
        workspaceAddons.append(try await localCommandAddonExecutables(
          in: workspaceRoot,
          allowedAddons: workspace.allowedAddons ?? []
        ))
      }
      let environmentNames = Set(workspaceEnvironments.flatMap(\.keys))
      let addonNames = Set(workspaceAddons.flatMap(\.keys))
      let environmentPresence = Dictionary(uniqueKeysWithValues: environmentNames.map { name in
        (name, workspaceEnvironments.allSatisfy { $0[name] == true })
      })
      let addonExecutables = Dictionary(uniqueKeysWithValues: addonNames.map { name in
        (name, workspaceAddons.allSatisfy { $0[name] == true })
      })
      return DistributedWorkerCapabilityMetadata(
        environment: environmentPresence,
        addonExecutables: addonExecutables
      )
    }

    func executionEnvironment(for workspace: Workspace, from environment: [String: String]) throws -> [String: String] {
      let requested = workspace.allowedEnvironment ?? []
      guard requested.allSatisfy(isValidEnvironmentVariableName) else { throw DistributedWorkerTransportError.invalidConfiguration }
      let baseline: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TZ"]
      let allowed = baseline.union(requested)
      return environment.filter { allowed.contains($0.key) && $0.key != tokenEnvironment }
    }

    func resolveToken(relativeTo configURL: URL, environment: [String: String]) throws -> String {
      switch (tokenEnvironment, tokenFile) {
      case (.some(let key), nil):
        guard let token = environment[key] else { throw DistributedWorkerTransportError.invalidConfiguration }
        return token
      case (nil, .some(let path)):
        guard !path.isEmpty else { throw DistributedWorkerTransportError.invalidConfiguration }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
          : configURL.deletingLastPathComponent().appendingPathComponent(path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 259) ?? Data()
        guard bytes.count <= 258, var token = String(data: bytes, encoding: .utf8) else {
          throw DistributedWorkerTransportError.invalidConfiguration
        }
        if token.hasSuffix("\r\n") || token.hasSuffix("\n") { token.removeLast() }
        return token
      default:
        throw DistributedWorkerTransportError.invalidConfiguration
      }
    }
  }

  func run(arguments: [String], onReady: @escaping @Sendable (String) -> Void) async -> CLICommandResult {
    if arguments.count == 4, arguments[0...2] == ["worker", DistributedWorkerClientAction.status.rawValue, "--config"] {
      do {
        let url = URL(fileURLWithPath: arguments[3])
        let config = try DistributedControllerConfiguration.load(from: url)
        let controller = try config.controller(relativeTo: url)
        let status = try await controller.workers(now: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let text = String(data: try encoder.encode(status), encoding: .utf8) else {
          throw DistributedWorkerTransportError.invalidResponse
        }
        return CLICommandResult(exitCode: .success, stdout: text + "\n")
      } catch {
        return CLICommandResult(exitCode: .failure, stderr: "Cannot read controller worker status.")
      }
    }
    if arguments == ["worker", "--help"] {
      return CLICommandResult(exitCode: .success, stdout: """
      Usage: riela worker --config <worker.json>
             riela worker status --config <controller.json>
      Connect outbound to a RielaApp or serve controller, or inspect controller-local status.
      worker.json specifies controllerURL, capacity, workspaces and either tokenFile or tokenEnvironment.

      """)
    }
    guard arguments.count == 3, arguments[0] == "worker", arguments[1] == "--config" else {
      return CLICommandResult(exitCode: .usage, stderr: "Usage: riela worker --config <worker.json>")
    }
    do {
      let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
      let configURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
      let bytes = try Data(contentsOf: configURL)
      guard bytes.count <= 1024 * 1024 else { throw DistributedWorkerTransportError.invalidConfiguration }
      let config = try JSONDecoder().decode(Configuration.self, from: bytes)
      guard !config.workspaces.isEmpty else {
        throw DistributedWorkerTransportError.invalidConfiguration
      }
      let token = try config.resolveToken(relativeTo: configURL, environment: environment)
      let declarations = try backendDeclarations(config.backends ?? [:])
      let observedAt = Date()
      let observedCapabilities = await BackendCapabilityProbe().probeAll(
        environment: environment, now: observedAt
      )
      let capabilities = BackendCapabilityMerger.merge(
        observations: observedCapabilities,
        declarations: declarations
      )
      let capabilityMetadata = try await config.registrationCapabilityMetadata(
        relativeTo: configURL,
        inheritedEnvironment: environment
      )
      let client = try DistributedWorkerHTTPClient(
        controllerURL: config.controllerURL,
        token: token,
        allowInsecureHTTP: config.allowInsecureHTTP ?? false,
        initialCapabilities: DistributedWorkerCapabilityObservation(
          capabilities: capabilities,
          environment: capabilityMetadata.environment,
          addonExecutables: capabilityMetadata.addonExecutables,
          observedAt: observedAt
        ),
        capabilityProvider: {
          let refreshedAt = Date()
          let observations = await BackendCapabilityProbe().probeAll(
            environment: environment, now: refreshedAt
          )
          let metadata = try await config.registrationCapabilityMetadata(
            relativeTo: configURL,
            inheritedEnvironment: environment
          )
          return DistributedWorkerCapabilityObservation(
            capabilities: BackendCapabilityMerger.merge(
              observations: observations,
              declarations: declarations
            ),
            environment: metadata.environment,
            addonExecutables: metadata.addonExecutables,
            observedAt: refreshedAt
          )
        }
      )
      var executors: [String: DistributedWorkerNodeExecutor] = [:]
      for (name, definition) in config.workspaces {
        let root = definition.path.hasPrefix("/") ? URL(fileURLWithPath: definition.path)
          : configURL.deletingLastPathComponent().appendingPathComponent(definition.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
          throw DistributedWorkerTransportError.invalidConfiguration
        }
        let executionEnvironment = try config.executionEnvironment(for: definition, from: environment)
        let runner = DistributedWorkerProcessRunner(environment: executionEnvironment)
        let addons = try await makeProductionAddonResolver(workingDirectory: root, environment: executionEnvironment,
          mockScenarioPath: nil, processRunner: runner)
        executors[name] = DistributedWorkerNodeExecutor(
          workspaces: [name: .init(root: root, controllerRoot: definition.controllerPath)],
          adapter: makeProductionNodeAdapter(environment: executionEnvironment),
          stdio: LocalWorkflowStdioNodeExecutor(runner: runner, hostEnvironment: executionEnvironment), addons: addons,
          allowedAddons: definition.allowedAddons ?? [], environment: executionEnvironment
        )
      }
      let configuredExecutors = executors
      let loop = try DistributedWorkerLoop(
        client: client,
        capacity: config.capacity,
        capabilities: capabilities,
        environment: capabilityMetadata.environment,
        addonExecutables: capabilityMetadata.addonExecutables,
        contextualExecutor: { job, registration in
          let request = try JSONDecoder().decode(
            DistributedNodeRequest.self,
            from: JSONEncoder().encode(job.payload)
          )
          guard let executor = configuredExecutors[request.workspace] else {
            throw DistributedWorkerTransportError.invalidConfiguration
          }
          let sender = DistributedWorkerEventSender(client: client, registration: registration, job: job)
          do {
            let result = try await executor.execute(
              job,
              backendEventHandler: { event in await sender.record(event) }
            )
            try await sender.finish()
            return result
          } catch {
            await sender.cancel()
            throw error
          }
        }
      )
      onReady("Worker connecting to controller; capacity \(config.capacity).\n")
      try await loop.run()
      return CLICommandResult(exitCode: .success)
    } catch is CancellationError {
      return CLICommandResult(exitCode: .success)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "Worker stopped: configuration, connection, or execution lease failed.")
    }
  }
}

struct DistributedWorkerCapabilityMetadata: Sendable {
  var environment: [String: Bool]
  var addonExecutables: [String: Bool]
}

private func localCommandAddonExecutables(
  in workingDirectory: URL,
  allowedAddons: Set<String>
) async throws -> [String: Bool] {
  guard !allowedAddons.isEmpty else { return [:] }
  let parsed = try ParsedParityOptions(["--scope", "auto", "--working-dir", workingDirectory.path])
  let loader = FileWorkflowPackageManifestLoader()
  var availability: [String: Bool] = [:]
  for root in packageRoots(parsed: parsed, workingDirectory: workingDirectory)
    where FileManager.default.fileExists(atPath: root.path) {
    guard let manifestURLs = try? packageManifestURLs(in: root) else { continue }
    for manifestURL in manifestURLs {
      guard let manifest = try? await loader.loadManifest(from: manifestURL) else { continue }
      let packageRoot = manifestURL.deletingLastPathComponent()
      for addon in manifest.nodeAddons where allowedAddons.contains(addon.name) {
        guard addon.execution?.kind == .localCommand,
          let entrypoint = addon.execution?.entrypoint, !entrypoint.isEmpty else { continue }
        let executable = packageRoot
          .appendingPathComponent(addon.sourcePath, isDirectory: true)
          .appendingPathComponent(entrypoint)
        let isAvailable = FileManager.default.isExecutableFile(atPath: executable.path)
        availability[entrypoint] = (availability[entrypoint] ?? false) || isAvailable
      }
    }
  }
  return availability
}

private func backendDeclarations(
  _ values: [String: BackendCapabilityDeclaration]
) throws -> [NodeExecutionBackend: BackendCapabilityDeclaration] {
  var result: [NodeExecutionBackend: BackendCapabilityDeclaration] = [:]
  for (name, declaration) in values {
    guard let backend = NodeExecutionBackend(rawValue: name), result[backend] == nil else {
      throw DistributedWorkerTransportError.invalidConfiguration
    }
    result[backend] = declaration
  }
  return result
}

func configuredDistributedExecutor(environment: [String: String]) throws -> (any DistributedNodeExecuting)? {
  guard let path = environment[DistributedControllerConfiguration.environmentKey], !path.isEmpty else { return nil }
  let url = URL(fileURLWithPath: path)
  let config = try DistributedControllerConfiguration.load(from: url)
  return QueuedDistributedNodeExecutor(controller: try config.controller(relativeTo: url))
}
