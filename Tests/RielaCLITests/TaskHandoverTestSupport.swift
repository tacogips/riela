import Foundation
import RielaCore
import RielaWork
@testable import RielaCLI

final class TaskHandoverRepositoryFixture {
  let root: URL
  let bareRemote: URL
  let clone: URL
  let baseRevision: String

  init() throws {
    root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/work-handover/wh-14-task-dispatch-runtime/repositories/\(UUID().uuidString)", isDirectory: true)
    bareRemote = root.appendingPathComponent("remote.git", isDirectory: true)
    clone = root.appendingPathComponent("clone", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    _ = try Self.runGit(["init", "--bare", bareRemote.path], at: root)
    _ = try Self.runGit(["clone", bareRemote.path, clone.path], at: root)
    _ = try Self.runGit(["config", "user.name", "Riela Test"], at: clone)
    _ = try Self.runGit(["config", "user.email", "riela-test@example.invalid"], at: clone)
    try "base".write(to: clone.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    _ = try Self.runGit(["add", "--", "README.md"], at: clone)
    _ = try Self.runGit(["commit", "-m", "initial"], at: clone)
    _ = try Self.runGit(["push", "origin", "HEAD:refs/heads/main"], at: clone)
    baseRevision = try Self.runGit(["rev-parse", "HEAD"], at: clone)
  }

  func secondClone(named name: String = "successor") throws -> URL {
    let destination = root.appendingPathComponent(name, isDirectory: true)
    _ = try Self.runGit(["clone", bareRemote.path, destination.path], at: root)
    return destination
  }

  func write(_ content: String, to path: String, in directory: URL? = nil) throws {
    let file = (directory ?? clone).appendingPathComponent(path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: file, atomically: true, encoding: .utf8)
  }

  func git(_ arguments: [String], at directory: URL? = nil) throws -> String {
    try Self.runGit(arguments, at: directory ?? clone)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  private static func runGit(_ arguments: [String], at directory: URL) throws -> String {
    let result = try FoundationGitCommandRunner().run(GitCommandInvocation(
      executableURL: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: arguments,
      workingDirectory: directory,
      environment: ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, value in value },
      standardInput: nil
    ))
    guard result.exitCode == 0 else {
      throw NSError(domain: "TaskHandoverRepositoryFixture", code: Int(result.exitCode),
                    userInfo: [NSLocalizedDescriptionKey: result.output])
    }
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct TaskHandoverTestHostResolver: HostCapabilityResolving {
  var traits: [HostTrait] = []

  func resolve(
    host: String,
    scope: WorkflowScope,
    workingDirectory: String,
    readOnly: Bool,
    localAddonExecutables: [String: Bool]
  ) async throws -> [HostCapabilitySnapshot] {
    [HostCapabilitySnapshot(
      hostId: "local", capacity: 1, backends: [], refreshedAt: Date(), traits: traits
    )]
  }
}

extension TaskExampleHarness {
  func handoverEnvelopeBundle(workflowId: String) -> ResolvedWorkflowBundle {
    let question: JSONObject = ["id": .string("q1"), "text": .string("Choose"), "options": .array([])]
    let addon = WorkflowNodeAddonRef(
      name: "riela/handover-request", version: "1", config: [
        "reason": .string("userInputRequired"),
        "question": .object(question),
        "progressNote": .string("Waiting for the answer"),
        "resumeStepId": .string("resume")
      ]
    )
    let workflow = WorkflowDefinition(
      workflowId: workflowId,
      defaults: .init(nodeTimeoutMs: 2_000, maxLoopIterations: 1),
      entryStepId: "prelude",
      nodeRegistry: [
        .init(id: "prelude", nodeFile: "prelude.json"),
        .init(id: "request", addon: addon),
        .init(id: "resume", nodeFile: "resume.json")
      ],
      steps: [
        .init(id: "prelude", nodeId: "prelude", transitions: [.init(toStepId: "request")]),
        .init(id: "request", nodeId: "request", transitions: [.init(toStepId: "resume")]),
        .init(id: "resume", nodeId: "resume")
      ],
      nodes: [
        .init(id: "prelude", nodeFile: "prelude.json"),
        .init(id: "request", addon: addon),
        .init(id: "resume", nodeFile: "resume.json")
      ]
    )
    return ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: ["prelude": .init(
        id: "prelude", nodeType: .command, model: "",
        command: .init(executable: "/bin/echo", arguments: ["{\"ready\":true}"])
      ), "resume": .init(
        id: "resume", nodeType: .command, model: "",
        command: .init(executable: "/usr/bin/true", arguments: [])
      )],
      sourceScope: .project, workflowDirectory: repository.path
    )
  }
}
