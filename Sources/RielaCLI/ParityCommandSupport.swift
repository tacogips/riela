import Foundation
import RielaAdapters
import RielaAddons
import RielaCore
import RielaEvents
import RielaGraphQL
import RielaHook
import RielaServer

struct ParsedParityOptions: Sendable {
  var scope: WorkflowScope = .project
  var workingDirectory: String?
  var workflowDefinitionDir: String?
  var source: String?
  var destination: String?
  var overwrite = false
  var exactYes = false
  var dryRun = false
  var check = false
  var locked = false
  var variables: String?
  var nodePatch: String?
  var mockScenarioPath: String?
  var sessionStore: String?
  var artifactRoot: String?
  var messageJSON: String?
  var messageFile: String?
  var promptVariant: String?
  var continueSession = false
  var resumeStepExecutionId: String?
  var timeoutMs: Int?
  var eventRoot: String?
  var eventFile: String?
  var readOnly = false
  var status: String?
  var limit: Int?
  var reason: String?
  var registry: String?
  var registryURL: String?
  var packageTags: [String] = []
  var packageBackends: [String] = []
  var refresh = false
  var noDependencies = false
  var all = false
  var packageName: String?
  var packageID: String?
  var branch: String?
  var localPath: String?
  var noteAPIEnabled = false
  var host: String?
  var port: Int?
  var noteRoot: String?
  var graphQLQuery: String?
  var graphQLQueryFile: String?
  var graphQLOperationName: String?
  var changeSetId: String?
  var expectedDigest: String?
  var sourceSessionId: String?
  var proposalId: String?
  var reviewSessionId: String?

  init(_ arguments: [String]) throws {
    var index = 0
    while index < arguments.count {
      let token = arguments[index]
      var valueIndex = index
      func value() throws -> String {
        guard valueIndex + 1 < arguments.count, !arguments[valueIndex + 1].hasPrefix("--") else {
          throw CLIUsageError("\(token) requires a value")
        }
        valueIndex += 1
        return arguments[valueIndex]
      }

      if try parseScopeAndPathOption(token, value: value) {
        index = valueIndex + 1
        continue
      }
      if try parseRuntimeOption(token, value: value) {
        index = valueIndex + 1
        continue
      }
      if try parseEventAndPackageOption(token, value: value) {
        index = valueIndex + 1
        continue
      }
      if try parseServeOption(token, value: value) {
        index = valueIndex + 1
        continue
      }
      if try parseGraphQLDocumentOption(token, value: value) {
        index = valueIndex + 1
        continue
      }
      if token.hasPrefix("--output=") {
        index += 1
        continue
      }
      throw CLIUsageError("unknown option '\(token)'")
    }
  }

  private mutating func parseScopeAndPathOption(_ token: String, value: () throws -> String) throws -> Bool {
    switch token {
    case "--scope":
      let raw = try value()
      guard let parsed = WorkflowScope(rawValue: raw), parsed != .direct else {
        throw CLIUsageError("invalid --scope value '\(raw)'; expected auto, project, or user")
      }
      scope = parsed == .auto ? .project : parsed
    case "--working-dir", "--working-directory":
      workingDirectory = try value()
    case "--change-set-id":
      changeSetId = try value()
    case "--expected-digest":
      expectedDigest = try value()
    case "--source-session-id":
      sourceSessionId = try value()
    case "--proposal-id":
      proposalId = try value()
    case "--review-session-id":
      reviewSessionId = try value()
    case "--workflow-definition-dir":
      workflowDefinitionDir = try value()
    case "--source", "--from":
      source = try value()
    case "--destination", "--dest", "--to":
      destination = try value()
    default:
      return false
    }
    return true
  }

  private mutating func parseRuntimeOption(_ token: String, value: () throws -> String) throws -> Bool {
    switch token {
    case "--overwrite", "--force", "-f":
      overwrite = true
    case "--yes":
      overwrite = true
      exactYes = true
    case "--dry-run":
      dryRun = true
    case "--check":
      check = true
    case "--locked":
      locked = true
    case "--variables":
      variables = try value()
    case "--node-patch":
      nodePatch = try value()
    case "--mock-scenario":
      mockScenarioPath = try value()
    case "--session-store":
      sessionStore = try value()
    case "--artifact-root":
      artifactRoot = try value()
    case "--message-json":
      messageJSON = try value()
    case "--message-file":
      messageFile = try value()
    case "--prompt-variant":
      promptVariant = try value()
    case "--continue-session":
      continueSession = true
    case "--resume-step-exec":
      resumeStepExecutionId = try value()
    case "--timeout-ms":
      guard let parsed = Int(try value()), parsed > 0 else {
        throw CLIUsageError("--timeout-ms requires a positive integer")
      }
      timeoutMs = parsed
    default:
      return false
    }
    return true
  }

  private mutating func parseEventAndPackageOption(_ token: String, value: () throws -> String) throws -> Bool {
    switch token {
    case "--event-root":
      eventRoot = try value()
    case "--event-file", "--file":
      eventFile = try value()
    case "--read-only":
      readOnly = true
    case "--status":
      status = try value()
    case "--limit":
      guard let parsed = Int(try value()), parsed > 0 else {
        throw CLIUsageError("--limit requires a positive integer")
      }
      limit = parsed
    case "--tag":
      packageTags.append(try value())
    case "--backend":
      packageBackends.append(try value())
    case "--refresh":
      refresh = true
    case "--no-dependencies":
      noDependencies = true
    case "--all":
      all = true
    case "--reason":
      reason = try value()
    case "--registry":
      registry = try value()
    case "--registry-url":
      registryURL = try value()
    case "--package-name":
      packageName = try value()
    case "--package-id":
      packageID = try value()
    case "--branch":
      branch = try value()
    case "--local-path", "--registry-local-path":
      localPath = try value()
    case "--output":
      _ = try value()
    default:
      return false
    }
    return true
  }

  private mutating func parseServeOption(_ token: String, value: () throws -> String) throws -> Bool {
    switch token {
    case "--note-api":
      noteAPIEnabled = true
    case "--host":
      host = try value()
    case "--port":
      guard let parsed = Int(try value()), (1...65_535).contains(parsed) else {
        throw CLIUsageError("--port requires an integer from 1 through 65535")
      }
      port = parsed
    case "--note-root":
      noteRoot = (try value() as NSString).expandingTildeInPath
    default:
      return false
    }
    return true
  }

  private mutating func parseGraphQLDocumentOption(_ token: String, value: () throws -> String) throws -> Bool {
    switch token {
    case "--query", "--document":
      graphQLQuery = try value()
    case "--query-file", "--document-file":
      graphQLQueryFile = try value()
    case "--operation-name":
      graphQLOperationName = try value()
    default:
      return false
    }
    return true
  }
}

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
