import Foundation
import ArgumentParser
import RielaAdapters
import RielaAddons
import RielaCore
import RielaEvents
import RielaGraphQL
import RielaHook
import RielaServer

struct ParsedParityOptions: ParsableArguments, Sendable {
  @Option var scope: WorkflowScope = .project
  @Option(name: [.customLong("working-dir"), .customLong("working-directory")]) var workingDirectory: String?
  @Option var workflowDefinitionDir: String?
  @Option(name: [.customLong("source"), .customLong("from")]) var source: String?
  @Option(name: [.customLong("destination"), .customLong("dest"), .customLong("to")]) var destination: String?
  @Flag(name: [.customLong("overwrite"), .customLong("force"), .customShort("f")]) var overwrite = false
  @Flag(name: .customLong("yes")) var exactYes = false
  @Flag var dryRun = false
  @Flag var check = false
  @Flag var locked = false
  @Option var variables: String?
  @Option var nodePatch: String?
  @Option(name: .customLong("mock-scenario")) var mockScenarioPath: String?
  @Option var sessionStore: String?
  @Option var artifactRoot: String?
  @Option var messageJSON: String?
  @Option var messageFile: String?
  @Option var promptVariant: String?
  @Flag var continueSession = false
  @Option(name: .customLong("resume-step-exec")) var resumeStepExecutionId: String?
  @Option var timeoutMs: Int?
  @Option var eventRoot: String?
  @Option(name: [.customLong("event-file"), .customLong("file")]) var eventFile: String?
  @Flag var readOnly = false
  @Flag(name: .customLong("include-children")) var includeChildren = false
  @Option var status: String?
  @Option var limit: Int?
  @Option var reason: String?
  @Option var registry: String?
  @Option var registryURL: String?
  @Option(name: .customLong("tag")) var packageTags: [String] = []
  @Option(name: .customLong("backend")) var packageBackends: [String] = []
  @Flag var refresh = false
  @Flag var noDependencies = false
  @Flag var all = false
  @Option var packageName: String?
  @Option(name: .customLong("package-id")) var packageID: String?
  @Flag(name: .customLong("create-pr")) var createPR = false
  @Option var prBase: String?
  @Option var preInstallCheck: WorkflowPackagePreInstallMode?
  @Option var preInstallCheckContainer: WorkflowPackageContainerRuntimeRequest?
  @Option var branch: String?
  @Option(name: [.customLong("local-path"), .customLong("registry-local-path")]) var localPath: String?
  @Flag(name: .customLong("note-api")) var noteAPIEnabled = false
  @Option var host: String?
  @Option var port: Int?
  @Option var noteRoot: String?
  @Option(name: [.customLong("query"), .customLong("document")]) var graphQLQuery: String?
  @Option(name: [.customLong("query-file"), .customLong("document-file")]) var graphQLQueryFile: String?
  @Option(name: .customLong("operation-name")) var graphQLOperationName: String?
  @Option var changeSetId: String?
  @Option var expectedDigest: String?
  @Option var sourceSessionId: String?
  @Option var proposalId: String?
  @Option var reviewSessionId: String?
  @Option var output: String?

  init() {}

  init(_ arguments: [String]) throws {
    do {
      self = try Self.parse(arguments)
    } catch {
      throw CLIUsageError(Self.message(for: error))
    }
  }

  mutating func validate() throws {
    if scope == .direct {
      throw ValidationError("invalid --scope value 'direct'; expected auto, project, or user")
    }
    if scope == .auto {
      scope = .project
    }
    if exactYes {
      overwrite = true
    }
    if let timeoutMs, timeoutMs <= 0 {
      throw ValidationError("--timeout-ms requires a positive integer")
    }
    if let limit, limit <= 0 {
      throw ValidationError("--limit requires a positive integer")
    }
    if let port, !(1...65_535).contains(port) {
      throw ValidationError("--port requires an integer from 1 through 65535")
    }
    if let noteRoot {
      self.noteRoot = (noteRoot as NSString).expandingTildeInPath
    }
  }
}

extension WorkflowScope: ExpressibleByArgument {}
extension WorkflowPackagePreInstallMode: ExpressibleByArgument {}
extension WorkflowPackageContainerRuntimeRequest: ExpressibleByArgument {}

func scopedWorkflowRoot(scope: WorkflowScope, workingDirectory: URL) -> URL {
  switch scope {
  case .user:
    return URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory()).appendingPathComponent(".riela/workflows", isDirectory: true)
  case .auto, .project, .direct:
    return workingDirectory.appendingPathComponent(".riela/workflows", isDirectory: true)
  }
}

func isURL(_ url: URL, containedIn root: URL) -> Bool {
  let childPath = url.standardizedFileURL.path
  let rootPath = root.standardizedFileURL.path
  return childPath == rootPath || childPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/")
}

func isParityASCIIAlphaNumeric(_ scalar: UnicodeScalar) -> Bool {
  let value = scalar.value
  return (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
}

func render<T: Encodable>(
  _ value: T,
  options: CLICommandOptions,
  text: (T) -> String
) throws -> CLICommandResult {
  switch options.output {
  case .json, .jsonl:
    return CLICommandResult(exitCode: .success, stdout: try jsonString(value))
  case .text, .table:
    return CLICommandResult(exitCode: .success, stdout: text(value))
  }
}

func failure(_ message: String, output: WorkflowOutputFormat, options: CLICommandOptions) -> CLICommandResult {
  if output.isStructured {
    let payload = CLIUnsupportedCommandResult(
      scope: options.scope,
      command: options.command,
      target: options.target,
      exitCode: CLIExitCode.failure.rawValue,
      error: message
    )
    return CLICommandResult(exitCode: .failure, stdout: (try? jsonString(payload)) ?? "")
  }
  return CLICommandResult(exitCode: .failure, stderr: message)
}

func scaffoldWorkflowJSON(workflowName: String) -> String {
  """
  {
    "workflowId": "\(workflowName)",
    "description": "Created by Riela Swift CLI",
    "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
    "entryStepId": "main-worker",
    "nodes": [{ "id": "main-worker", "nodeFile": "nodes/node-main-worker.json" }],
    "steps": [{ "id": "main-worker", "nodeId": "main-worker", "role": "worker" }]
  }
  """
}

func scaffoldNodeJSON() -> String {
  """
  {
    "id": "main-worker",
    "executionBackend": "codex-agent",
    "model": "gpt-5.5",
    "modelFreeze": false,
    "prompt": "Return a concise JSON object with a status field.",
    "variables": {}
  }
  """
}
