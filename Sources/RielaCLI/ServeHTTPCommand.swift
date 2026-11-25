import Foundation
import RielaCore
import RielaGraphQL
import RielaServer
import RielaObservability
import RielaWorkflowRegistry

struct ServeHTTPCommand: Sendable {
  typealias ReadyHandler = @Sendable (String) -> Void

  static func isLongRunningInvocation(_ arguments: [String]) -> Bool {
    guard case let .scoped(command) = try? RielaArgumentParser().parse(arguments) else {
      return false
    }
    return command.kind == .serve && command.options.command == nil
  }

  func run(arguments: [String], onReady: @escaping ReadyHandler) async -> CLICommandResult {
    guard case let .scoped(command) = try? RielaArgumentParser().parse(arguments),
          command.kind == .serve,
          command.options.command == nil else {
      return CLICommandResult(exitCode: .usage, stderr: "long-running serve requires bare `riela serve`")
    }
    do {
      let parsed = try ParsedParityOptions(command.options.arguments)
      guard parsed.pairingScope == nil || parsed.pairingAddress != nil else {
        return CLICommandResult(exitCode: .usage, stderr: "--pairing-scope requires --pairing-address")
      }
      return try await run(command: command, parsed: parsed, onReady: onReady)
    } catch let error as RielaAPIKeyStore.StoreError {
      return CLICommandResult(exitCode: .failure, stderr: error.code)
    } catch let error as BotStoreError {
      return CLICommandResult(exitCode: .usage, stderr: error.code)
    } catch let error as CLIUsageError {
      return failure(error.message, output: command.options.output, options: command.options)
    } catch {
      return failure("\(error)", output: command.options.output, options: command.options)
    }
  }

  private func run(
    command: ScopedCommand,
    parsed: ParsedParityOptions,
    onReady: @escaping ReadyHandler
  ) async throws -> CLICommandResult {
    if let address = parsed.pairingAddress { _ = try RielaPairingAddress.validate(address) }
    let pairingScope = try PairingService.scope(parsed.pairingScope)
    let host = parsed.host ?? "127.0.0.1"
    let requestedPort = parsed.port ?? ServeWebSettingsStore(
      homeDirectory: URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(), isDirectory: true)
    ).loadPort() ?? 8787
    let webRoot = try resolvedServeWebRoot(parsed: parsed)
    let configuration = RielaServerConfiguration(
      host: host,
      port: requestedPort,
    )
    let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    let environment = try await CLIRuntimeEnvironmentPreparation.prepare(path: parsed.runtimeEnvironmentFile,
      required: [], base: CLIRuntimeEnvironment.mergedProcessEnvironment(), workingDirectory: workingDirectory)
    let sessionRoot = CLIWorkflowSessionStore.resolveRootDirectory(
      sessionStore: parsed.sessionStore,
      scope: parsed.scope,
      workingDirectory: workingDirectory,
      environment: environment
    )
    let homeDirectory = URL(
      fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(environment: environment), isDirectory: true
    )
    let pairing = try PairingService(store: serverAPIKeyStore(homeDirectory: homeDirectory), serverName: parsed.serverName)
    let adapter = serveMachineGraphQLAdapter(
      parsed: parsed, environment: environment, workingDirectory: workingDirectory, pairing: pairing
    )
    let distributedHost = try environment[DistributedControllerConfiguration.environmentKey].map {
      try DistributedControllerHost(
        configurationURL: URL(fileURLWithPath: $0),
        environment: environment,
        capabilityStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionRoot)
      )
    }
    let webHost = await ServeWebHost(
      homeDirectory: homeDirectory,
      workingDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true),
      sessionStoreRoot: parsed.sessionStore,
      host: host,
      port: requestedPort,
      fallback: adapter,
      environment: environment,
      pairing: pairing
    )
    let routeHandler: any RielaHTTPRouteHandling
    if let webRoot {
      routeHandler = RielaStaticSPAHTTPRouter(service: webHost, webRoot: webRoot)
    } else {
      routeHandler = webHost
    }
    let server = RielaLocalHTTPServer(routeHandler: routeHandler)
    let listenerHandle = try await inProcessListener(configuration: configuration)
    let boundPort: Int
    let pairingCode: PairingCodePayload?
    do {
      boundPort = try await server.start(host: host, port: requestedPort)
      try await distributedHost?.start()
      pairingCode = try parsed.pairingAddress.map { try pairing.mint(address: $0, scope: pairingScope) }
    } catch {
      await server.stop()
      await distributedHost?.stop()
      try? await listenerHandle.shutdown()
      throw error
    }
    await webHost.updateBoundPort(boundPort)
    await webHost.startConfiguredInstances()
    let endpoint = "http://\(host):\(boundPort)"
    let readyResult = ScopedParityCommandResult(
      scope: "serve",
      command: nil,
      target: nil,
      status: "running",
      records: readyRecords(
        endpoint: endpoint,
        webRoot: webRoot
      )
    )
    let rendered = try render(readyResult, options: command.options) { result in
      result.records.joined(separator: "\n") + "\n"
    }
    onReady(rendered.stdout.hasSuffix("\n") ? rendered.stdout : rendered.stdout + "\n")
    if let pairingCode { onReady(pairingCode.terminalOutput) }

    let retentionRequest = RielaRetentionRequest(
      trigger: .automatic,
      homeDirectory: URL(
        fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(environment: environment),
        isDirectory: true
      ),
      projectDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true),
      explicitSessionStore: parsed.sessionStore,
      environment: environment,
      scope: .all
    )
    let retentionScheduler = RielaRetentionScheduler(runImmediately: false) {
      for warning in AutomaticRetentionHook.runAutomaticPass(retentionRequest) {
        RielaStandardStreams.writeError(Data((warning + "\n").utf8))
      }
    }
    retentionScheduler.start()
    defer { retentionScheduler.stop() }

    let jobScheduler = BotJobScheduler { at in
      await BotJobScheduler.evaluate(in: BotsService(
        workingDirectory: workingDirectory, sessionStoreRoot: sessionRoot, environment: environment, now: { at }
      ))
    }
    let clock = SystemEventServeClock()
    let jobTicks = Task {
      while !Task.isCancelled {
        await jobScheduler.tickIfDue(now: clock.now())
        do {
          try await clock.sleep(for: .seconds(60))
        } catch {
          return
        }
      }
    }
    do {
      try await Task.sleep(nanoseconds: .max)
    } catch is CancellationError {
      // SIGINT and SIGTERM cancel the entry-point task.
    }
    jobTicks.cancel()
    await jobTicks.value
    await jobScheduler.shutdown()
    await server.stop()
    await webHost.shutdown()
    await distributedHost?.stop()
    try await listenerHandle.shutdown()
    return CLICommandResult(exitCode: .success)
  }

  private func inProcessListener(
    configuration: RielaServerConfiguration
  ) async throws -> InProcessWorkflowServeListenerHandle {
    let listener = try await InProcessWorkflowServeListenerFactory().startListener(
      for: WorkflowServeResolvedWorkflow(workflowId: "cli-serve", selectedIdentity: "cli-serve"),
      request: WorkflowServeStartRequest(selection: .scopedName("cli-serve"), server: configuration),
      generationId: "cli-serve"
    )
    guard let inProcessListener = listener as? InProcessWorkflowServeListenerHandle else {
      throw CLIUsageError("serve requires the in-process route listener")
    }
    return inProcessListener
  }

  private func readyRecords(
    endpoint: String,
    webRoot: URL?
  ) -> [String] {
    var records = ["endpoint=\(endpoint)"]
    if let webRoot {
      records.append("webRoot=\(webRoot.path)")
    }
    return records
  }
}

func serveMachineGraphQLAdapter(
  parsed: ParsedParityOptions,
  environment: [String: String],
  workingDirectory: String,
  pairing: PairingService? = nil
) -> DeterministicServerHTTPAdapter {
  let storeRoot = CLIWorkflowSessionStore.resolveRootDirectory(
    sessionStore: parsed.sessionStore,
    scope: parsed.scope,
    workingDirectory: workingDirectory,
    environment: environment
  )
  let provider = WorkflowExecutionProvider(
    workingDirectory: workingDirectory,
    sessionStoreRoot: storeRoot,
    environment: environment
  )
  let graphQLExecutor = APIKeyGraphQLAuthorization(
    store: pairing?.store ?? serverAPIKeyStore(homeDirectory: URL(
      fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(environment: environment), isDirectory: true
    )),
    next: CompositeGraphQLDocumentExecutor(
      workflowRegistry: WorkflowRegistryGraphQLDocumentExecutor(),
      fallback: WorkflowExecutionGraphQLDocumentExecutor(
        provider: provider,
        next: WorkflowDefinitionGraphQLDocumentExecutor(
          provider: WorkflowDefinitionGraphQLProvider(
            workingDirectory: workingDirectory,
            sessionStoreRoot: storeRoot,
            environment: environment
          ),
          next: TaskHandoverGraphQLDocumentExecutor(
          provider: TaskHandoverGraphQLProvider(
            workingDirectory: workingDirectory,
            sessionStore: storeRoot
          ),
          next: SessionControlGraphQLDocumentExecutor(
            provider: RielaSessionControlProvider(
              workingDirectory: workingDirectory,
              sessionStore: storeRoot
            ),
            next: BotsGraphQLDocumentExecutor(
              provider: BotsGraphQLProvider(
                workingDirectory: workingDirectory, sessionStoreRoot: storeRoot, environment: environment,
                pairing: pairing
              ),
              next: AskGraphQLHost.executor(
                workingDirectory: workingDirectory, sessionStore: storeRoot, scope: parsed.scope,
                environment: environment, pairing: pairing,
                next: RoutineGraphQLDocumentExecutor(
                  provider: FileRoutineGraphQLProvider(
                    workingDirectory: workingDirectory, environment: environment,
                    botExists: BotRunLinker.botExists(sessionStoreRoot: storeRoot)
                  ),
                  authorizeMachineCreate: { BotsRequestGrant.current?.isStillValid() == true }
                )
              )
            )
          )
          )
        )
      )
    )
  )
  return DeterministicServerHTTPAdapter(
    routeHandler: DeterministicServerRouteHandler(graphQLExecutor: graphQLExecutor),
    context: serveRequestContext(parsed: parsed)
  )
}

func resolvedServeWebRoot(parsed: ParsedParityOptions) throws -> URL? {
  guard let raw = parsed.webRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
        !raw.isEmpty else {
    return RielaWebAssetLocator.locate()
  }
  let root = URL(fileURLWithPath: raw, isDirectory: true)
    .standardizedFileURL
    .resolvingSymlinksInPath()
  let index = root
    .appendingPathComponent("index.html", isDirectory: false)
    .standardizedFileURL
    .resolvingSymlinksInPath()
  let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
  var isDirectory: ObjCBool = false
  let indexValues = try? index.resourceValues(forKeys: [.isRegularFileKey])
  guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
        isDirectory.boolValue,
        FileManager.default.isReadableFile(atPath: root.path),
        index.path.hasPrefix(rootPrefix),
        indexValues?.isRegularFile == true,
        FileManager.default.isReadableFile(atPath: index.path) else {
    throw CLIUsageError("--web-root requires a readable directory containing index.html")
  }
  return root
}

func resolvedServeNoteRoot(parsed: ParsedParityOptions) -> String {
  let raw = parsed.noteRoot
    ?? CLIRuntimeEnvironment.mergedProcessEnvironment()["RIELA_NOTE_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
    ?? "\(NSHomeDirectory())/.riela/note"
  return (raw as NSString).expandingTildeInPath
}

func serveRequestContext(parsed: ParsedParityOptions) -> ServerRequestContext {
  ServerRequestContext(inheritedEnvironment: parsed.sessionStore.map { ["RIELA_MANAGER_SESSION_ID": $0] } ?? [:])
}
