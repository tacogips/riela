import Foundation
import RielaCore
import RielaWorkflowRegistry

/// A hermetic production-composition smoke: it uses the normal parser/store,
/// compact catalog, selected registry load, canonical child reservation and
/// workflow runner.  It creates a throwaway registered workflow and does not
/// construct any Matrix/Wrike credential or network boundary.
struct SpecialistSmokeCommand: Sendable {
  func run(options: CLICommandOptions) async throws -> CLICommandResult {
    let parsed = try SpecialistCLIArguments(options)
    let root = URL(fileURLWithPath: parsed.stateRoot, isDirectory: true)
    let work = root.appendingPathComponent("smoke-work", isDirectory: true)
    let workflow = work.appendingPathComponent(".riela/workflows/specialist-smoke", isDirectory: true)
    try FileManager.default.createDirectory(at: workflow, withIntermediateDirectories: true)
    let definition = """
    {"workflowId":"specialist-smoke","description":"Hermetic specialist smoke workflow.",
    "defaults":{"maxLoopIterations":3,"nodeTimeoutMs":120000},
    "prompts":{"workerSystemPromptTemplate":"Return concise smoke JSON."},
    "entryStepId":"work","nodes":[{"id":"work","nodeFile":"nodes/work.json"}],
    "steps":[{"id":"work","nodeId":"work","role":"worker"}]}
    """
    let node = """
    {"id":"work","executionBackend":"codex-agent","model":"gpt-5.4-mini","modelFreeze":false,"promptTemplateFile":"prompts/work.md","variables":{},"output":{"description":"Return a smoke result."}}
    """
    let scenario = """
    {"work":{"provider":"scenario-mock","model":"gpt-5.4-mini","when":{"always":true},"payload":{"status":"ok"}}}
    """
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("prompts"), withIntermediateDirectories: true)
    try Data(definition.utf8).write(to: workflow.appendingPathComponent("workflow.json"), options: .atomic)
    try Data(node.utf8).write(to: workflow.appendingPathComponent("nodes/work.json"), options: .atomic)
    try Data("Return smoke JSON.".utf8).write(to: workflow.appendingPathComponent("prompts/work.md"), options: .atomic)
    try Data(scenario.utf8).write(to: work.appendingPathComponent("smoke-scenario.json"), options: .atomic)
    // Smoke may reuse a state root; refresh only its just-created fixture so a
    // prior immutable card never masks the current executable closure.
    _ = try WorkflowCompactCatalog().refresh(workingDirectory: work.path)
    let card = try WorkflowCompactCatalog().select(workflowId: "specialist-smoke", workingDirectory: work.path)
    let base = CLICommandOptions(scope: "specialist", command: "submit", target: "smoke-request", arguments: [
      "--state-root", parsed.stateRoot, "--working-dir", work.path, "--workflow", "specialist-smoke",
      "--variables", "{\"workflowInput\":{\"request\":\"smoke\"}}", "--specialist-config", work.appendingPathComponent("specialists.json").path,
      "--mock-scenario", work.appendingPathComponent("smoke-scenario.json").path
    ], output: .json)
    let runner = SpecialistCommandRunner()
    let specialistConfiguration = """
    {"specialists":[{"id":"smoke-specialist","capacity":1,"domain":"smoke","allowedOriginIds":["\(card.originId)"]}],
    "classifier":{"fixtureDecisions":[{"specialistId":"smoke-specialist","kind":"claim","reason":"smoke"}]}}
    """
    try Data(specialistConfiguration.utf8)
      .write(to: work.appendingPathComponent("specialists.json"), options: .atomic)
    let submitted = await runner.run(SpecialistCommand(kind: .submit, options: base))
    guard submitted.exitCode == .success else { return submitted }
    let dispatchId = "dispatch-smoke-request"
    let started = await runner.run(SpecialistCommand(kind: .execute, options: CLICommandOptions(
      scope: "specialist", command: "execute", target: dispatchId,
      arguments: ["--state-root", parsed.stateRoot, "--working-dir", work.path, "--mock-scenario", work.appendingPathComponent("smoke-scenario.json").path], output: .json
    )))
    guard started.exitCode == .success else { return started }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let execution = try decoder.decode(SpecialistCommandResult.self, from: Data(started.stdout.utf8))
    guard execution.accepted, execution.task?.state == .succeeded, execution.dispatch?.state == .terminal else {
      return CLICommandResult(exitCode: .failure, stderr: "specialist smoke child did not complete: \(started.stdout)")
    }
    let status = await runner.run(SpecialistCommand(kind: .status, options: CLICommandOptions(
      scope: "specialist", command: "status", target: "task-smoke-request", arguments: ["--state-root", parsed.stateRoot], output: .json
    )))
    guard status.exitCode == .success else { return status }
    let observed = try decoder.decode(SpecialistCommandResult.self, from: Data(status.stdout.utf8))
    guard observed.task?.state == .succeeded else {
      return CLICommandResult(exitCode: .failure, stderr: "specialist smoke status did not observe completed child: \(status.stdout)")
    }
    struct Result: Codable { let accepted: Bool; let mode: String; let dispatchId: String; let verification: String }
    return CLICommandResult(exitCode: .success, stdout: try jsonString(Result(
      accepted: true, mode: "stub-boundary-real-runner", dispatchId: dispatchId,
      verification: "reserved session resumed and completed through WorkflowRunCommand"
    )))
  }
}
