import Foundation
import RielaCore
import RielaServer

struct ServeHTTPCommand: Sendable {
  typealias ReadyHandler = @Sendable (String) -> Void

  /// Discovery seam for the default web root; production uses `RielaWebAssetLocator`.
  var locateWebAssets: @Sendable () -> URL? = { RielaWebAssetLocator.locate() }

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
      return try await run(command: command, parsed: parsed, onReady: onReady)
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
    let host = parsed.host ?? "127.0.0.1"
    let requestedPort = parsed.port ?? 8787
    let webRoot = try resolvedServeWebRoot(parsed: parsed, locateDefault: locateWebAssets)
    let configuration = RielaServerConfiguration(
      host: host,
      port: requestedPort,
    )
    let listenerHandle = try await inProcessListener(configuration: configuration)
    let adapter = DeterministicServerHTTPAdapter(
      routeHandler: listenerHandle.routeHandler,
      context: serveRequestContext(parsed: parsed)
    )
    let routeHandler: any RielaHTTPRouteHandling
    if let root = webRoot.root {
      routeHandler = RielaStaticSPAHTTPRouter(service: adapter, webRoot: root)
    } else {
      routeHandler = adapter
    }
    let server = RielaLocalHTTPServer(routeHandler: routeHandler)
    let boundPort = try await server.start(host: host, port: requestedPort)
    let endpoint = "http://\(host):\(boundPort)"
    let readyResult = ScopedParityCommandResult(
      scope: "serve",
      command: nil,
      target: nil,
      status: "running",
      records: Self.readyRecords(
        endpoint: endpoint,
        webRoot: webRoot
      )
    )
    let rendered = try render(readyResult, options: command.options) { result in
      result.records.joined(separator: "\n") + "\n"
    }
    onReady(rendered.stdout.hasSuffix("\n") ? rendered.stdout : rendered.stdout + "\n")

    do {
      try await Task.sleep(nanoseconds: .max)
    } catch is CancellationError {
      // SIGINT and SIGTERM cancel the entry-point task.
    }
    await server.stop()
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

  static func readyRecords(
    endpoint: String,
    webRoot: ServeWebRootResolution
  ) -> [String] {
    var records = ["endpoint=\(endpoint)"]
    if let root = webRoot.root {
      records.append("webRoot=\(root.path)")
      records.append("webRootSource=\(webRoot.source?.rawValue ?? ServeWebRootSource.located.rawValue)")
    } else {
      records.append("webRoot=none")
      records.append("webAssets=\(webRoot.diagnostic ?? ServeWebRootResolution.missingAssetsDiagnostic)")
    }
    return records
  }
}

/// Where the effective `serve` web root came from.
enum ServeWebRootSource: String, Sendable {
  case explicit = "--web-root"
  case located = "auto"
}

/// The outcome of resolving the `serve` web root. A `nil` root means API-only mode, which is
/// never an error: `diagnostic` then explains why no dashboard is being served.
struct ServeWebRootResolution: Equatable, Sendable {
  var root: URL?
  var source: ServeWebRootSource?
  var diagnostic: String?

  static let apiOnlyAdvice =
    "serving the API only. Build the dashboard with 'cd web && bun run build' or pass --web-root <dir>"
  static let missingAssetsDiagnostic = "missing; \(apiOnlyAdvice)"
  static let unavailable = ServeWebRootResolution(
    root: nil,
    source: nil,
    diagnostic: missingAssetsDiagnostic
  )

  static func rejected(_ url: URL) -> ServeWebRootResolution {
    ServeWebRootResolution(
      root: nil,
      source: nil,
      diagnostic: "rejected \(url.path); \(apiOnlyAdvice)"
    )
  }
}

/// Resolves the web root for `riela serve`.
///
/// An explicit `--web-root` always wins and still fails the command with the existing
/// `CLIUsageError` when it does not name a readable directory containing `index.html`.
/// Without it the located default is validated the same way but never throws: a missing or
/// unusable directory downgrades to API-only mode with a diagnostic.
func resolvedServeWebRoot(
  parsed: ParsedParityOptions,
  locateDefault: () -> URL? = { RielaWebAssetLocator.locate() }
) throws -> ServeWebRootResolution {
  if let raw = parsed.webRoot?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
    return ServeWebRootResolution(root: try validatedServeWebRoot(raw), source: .explicit)
  }
  guard let located = locateDefault() else {
    return .unavailable
  }
  guard let root = try? validatedServeWebRoot(located.path) else {
    return .rejected(located)
  }
  return ServeWebRootResolution(root: root, source: .located)
}

private func validatedServeWebRoot(_ raw: String) throws -> URL {
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
