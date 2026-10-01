import Foundation
import RielaCore
import RielaWork
@testable import RielaCLI

final class TaskHandoverRepositoryFixture {
  let root: URL
  let bareRemote: URL
  let clone: URL
  let baseRevision: String
  var gitEnvironment: [String: String] { TaskHandoverRuntime.gitEnvironment() }

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-handover-repositories/\(UUID().uuidString)", isDirectory: true)
    bareRemote = root.appendingPathComponent("remote.git", isDirectory: true)
    clone = root.appendingPathComponent("clone", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    _ = try Self.runGit(["init", "--bare", bareRemote.path], at: root)
    _ = try Self.runGit(["clone", bareRemote.path, clone.path], at: root)
    let resolvedRoot = URL(fileURLWithPath: try Self.runGit(["rev-parse", "--show-toplevel"], at: clone))
      .resolvingSymlinksInPath().standardizedFileURL.path
    let fixtureRoot = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    guard resolvedRoot.hasPrefix(fixtureRoot) else {
      throw NSError(domain: "TaskHandoverRepositoryFixture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "resolved repository escaped its temporary fixture root"])
    }
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
    _ = try Self.runGit(["clone", "--branch", "main", bareRemote.path, destination.path], at: root)
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
    let result = try TaskHandoverHermeticGit.run(
      arguments, at: directory,
      environment: TaskHandoverHermeticGit.environment(ceiling: FileManager.default.temporaryDirectory)
    )
    guard result.exitCode == 0 else {
      throw NSError(domain: "TaskHandoverRepositoryFixture", code: Int(result.exitCode),
                    userInfo: [NSLocalizedDescriptionKey: result.output])
    }
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Hermetic git helpers: fixtures live under a fresh temporary root and git discovery is capped by
/// `GIT_CEILING_DIRECTORIES` so it can never walk up into an enclosing (real) repository.
enum TaskHandoverHermeticGit {
  static func makeRoot(_ prefix: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.resolvingSymlinksInPath()
  }

  static func environment(ceiling: URL) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR"] {
      environment.removeValue(forKey: key)
    }
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_CEILING_DIRECTORIES"] = ceiling.path
    return environment
  }

  static func run(
    _ arguments: [String], at directory: URL, environment: [String: String]
  ) throws -> (exitCode: Int32, output: String) {
    let result = try FoundationGitCommandRunner().run(GitCommandInvocation(
      executableURL: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: arguments,
      workingDirectory: directory,
      environment: environment,
      standardInput: nil
    ))
    return (result.exitCode, result.output)
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

extension TaskExampleHarness {
  /// Writes a two-step command workflow under `<project>/.riela/workflows/<workflowId>` and saves a
  /// suspended operator-move session for it in this harness's session store.
  func writeSuspendedAdoptionFixture(project: URL, workflowId: String, sessionId: String) throws {
    let workflowDirectory = project.appendingPathComponent(".riela/workflows/\(workflowId)", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    let workflow: [String: Any] = [
      "workflowId": workflowId,
      "defaults": ["nodeTimeoutMs": 2_000, "maxLoopIterations": 1],
      "entryStepId": "start",
      "nodes": [["id": "node", "nodeFile": "node.json"]],
      "steps": [
        ["id": "start", "nodeId": "node", "transitions": [["toStepId": "resume"]]],
        ["id": "resume", "nodeId": "node"]
      ]
    ]
    let node: [String: Any] = [
      "id": "node", "nodeType": "command", "model": "", "modelFreeze": false,
      "command": ["executable": "/usr/bin/true", "arguments": []]
    ]
    try JSONSerialization.data(withJSONObject: workflow, options: [.sortedKeys])
      .write(to: workflowDirectory.appendingPathComponent("workflow.json"))
    try JSONSerialization.data(withJSONObject: node, options: [.sortedKeys])
      .write(to: workflowDirectory.appendingPathComponent("node.json"))
    let now = Date()
    let session = WorkflowSession(
      workflowId: workflowId, sessionId: sessionId, status: .suspended,
      entryStepId: "start", currentStepId: "resume", createdAt: now, updatedAt: now,
      suspend: SuspendRecord(
        reasonKind: .operatorMove, stepId: "resume", progressNote: "Resume adopted work",
        suspendedAt: now, producer: .runtime
      )
    )
    try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
    ).save(WorkflowRuntimePersistenceSnapshot(session: session))
  }

  /// A `TaskHandoverRuntime` over this harness's store, used only to call `adoptAndSeal`.
  func adoptionRuntime(workflowId: String, workingDirectory: URL) -> TaskHandoverRuntime {
    let placeholder = WorkTask(
      id: TaskID("task-adoption-placeholder"), intentId: IntentID("intent-adoption-placeholder"),
      title: "Adoption runtime", instruction: "unused", plan: .workflow(WorkflowReference(name: workflowId))
    )
    return TaskHandoverRuntime(
      located: TaskCommandRunner.LocatedTask(task: placeholder, store: store, root: store.rootDirectory),
      options: TaskStoreOptions(scope: .project, workingDirectory: workingDirectory.path, sessionStore: sessionStore.path)
    )
  }
}
