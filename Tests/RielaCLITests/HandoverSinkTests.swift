import Foundation
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

final class HandoverSinkTests: XCTestCase {
  private var root: URL!
  private var packet: HandoverPacket!
  private var bytes: Data!

  override func setUpWithError() throws {
    let unresolvedRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-wh09-handover-sinks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: unresolvedRoot, withIntermediateDirectories: true)
    root = hermeticRealPath(unresolvedRoot)
    packet = try samplePacket().sealed()
    bytes = try JSONCanonical.encode(packet)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testFileSinkRoundTripsAndRejectsDifferentOverwrite() async throws {
    let sink = FileHandoverSink(root: root.path)
    let ref = try await sink.write(packet, bytes: bytes, brief: "handover brief")
    let readBytes = try await sink.read(ref)
    XCTAssertEqual(try HandoverSinkVerification.verify(bytes: readBytes, ref: ref), packet)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("handovers/task-1/handover-1.md").path))
    let again = try await sink.write(packet, bytes: bytes, brief: "handover brief")
    XCTAssertEqual(again.locator, ref.locator)
    do {
      _ = try await sink.write(packet, bytes: Data("different".utf8), brief: "brief")
      XCTFail("expected an overwrite conflict")
    } catch let error as HandoverSinkError {
      guard case .conflictingContent = error else { return XCTFail("unexpected error: \(error)") }
    }
  }

  func testCommandSinkRoundTripsAndRejectsFailureAndEmptyId() async throws {
    let script = try writeScript("""
      #!/bin/sh
      root="$1"
      if [ "$2" = "--read" ]; then cat "$root/$3"; exit 0; fi
      cat > "$root/packet-1"
      printf 'packet-1\\n'
      """)
    let sink = CommandHandoverSink(argv: ["/bin/sh", script.path, root.path], workingDirectory: root.path)
    let ref = try await sink.write(packet, bytes: bytes, brief: "unused")
    XCTAssertEqual(ref.locator, "packet-1")
    let readBytes = try await sink.read(ref)
    XCTAssertEqual(try HandoverSinkVerification.verify(bytes: readBytes, ref: ref), packet)

    let failed = try writeScript("#!/bin/sh\nexit 3\n")
    let failedSink = CommandHandoverSink(argv: ["/bin/sh", failed.path], workingDirectory: root.path)
    do {
      _ = try await failedSink.write(packet, bytes: bytes, brief: "")
      XCTFail("expected command failure")
    } catch let error as HandoverSinkError {
      XCTAssertEqual(error, .commandFailed(3))
    }

    let empty = try writeScript("#!/bin/sh\nprintf '\\n'\n")
    let emptySink = CommandHandoverSink(argv: ["/bin/sh", empty.path], workingDirectory: root.path)
    do {
      _ = try await emptySink.write(packet, bytes: bytes, brief: "")
      XCTFail("expected empty id failure")
    } catch let error as HandoverSinkError {
      XCTAssertEqual(error, .invalidCommandOutput)
    }
  }

  func testGitRefSinkReadsFromFreshClone() async throws {
    let bare = root.appendingPathComponent("remote.git", isDirectory: true)
    let first = root.appendingPathComponent("first", isDirectory: true)
    let second = root.appendingPathComponent("second", isDirectory: true)
    try runGit(["init", "--bare", bare.path], cwd: root)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try runGit(["init", first.path], cwd: root)
    try runGit(["-C", first.path, "config", "user.email", "test@example.invalid"], cwd: root)
    try runGit(["-C", first.path, "config", "user.name", "Test"], cwd: root)
    try runGit(["-C", first.path, "remote", "add", "origin", bare.path], cwd: root)
    try runGit(["clone", bare.path, second.path], cwd: root)
    try assertTopLevelInsideFixture(first)
    try assertTopLevelInsideFixture(second)

    let ref = try await GitRefHandoverSink(repositoryRoot: first.path, remote: "origin").write(packet, bytes: bytes, brief: "unused")
    let reader = try HandoverSinkFactory.reader(for: ref, context: sinkContext(repositoryRoot: second.path))
    let readBytes = try await reader.read(ref)
    XCTAssertEqual(try HandoverSinkVerification.verify(bytes: readBytes, ref: ref), packet)
    var largePacket = packet!
    largePacket.id = HandoverID("handover-large")
    largePacket.workflow.workflowDefinitionDir = String(repeating: "x", count: 1_100_000)
    largePacket = try largePacket.sealed()
    let largeBytes = try JSONCanonical.encode(largePacket)
    XCTAssertGreaterThan(largeBytes.count, 1_048_576)
    let largeRef = try await GitRefHandoverSink(repositoryRoot: first.path, remote: "origin")
      .write(largePacket, bytes: largeBytes, brief: "unused")
    let largeRead = try await reader.read(largeRef)
    XCTAssertEqual(largeRead, largeBytes)
    XCTAssertEqual(try HandoverSinkVerification.verify(bytes: largeRead, ref: largeRef), largePacket)
    do {
      _ = try await GitRefHandoverSink(repositoryRoot: first.path, remote: "origin")
        .write(packet, bytes: Data("other".utf8), brief: "")
      XCTFail("expected remote ref conflict")
    } catch let error as HandoverSinkError {
      guard case .conflictingContent = error else { return XCTFail("unexpected error: \(error)") }
    }
  }

  func testGitRefSinkPassesMinimalGitEnvironment() async throws {
    let runner = RecordingGitRunner()
    let sink = GitRefHandoverSink(repositoryRoot: root.path, remote: "origin", runner: runner, environment: [
      "HOME": "/home/x", "SSH_AUTH_SOCK": "/s", "PATH": "/usr/bin", "SECRET_TOKEN": "t"
    ])
    do {
      _ = try await sink.write(packet, bytes: bytes, brief: "unused")
      XCTFail("expected git failure")
    } catch {}
    let environment = try XCTUnwrap(runner.invocations().first).environment
    XCTAssertEqual(environment["HOME"], "/home/x")
    XCTAssertEqual(environment["SSH_AUTH_SOCK"], "/s")
    XCTAssertEqual(environment["PATH"], "/usr/bin")
    XCTAssertEqual(environment["GIT_TERMINAL_PROMPT"], "0")
    XCTAssertNil(environment["SECRET_TOKEN"])
  }

  func testKaibaSinkRoundTripsBriefAndTags() async throws {
    let client = FakeKaibaHandoverNoteClient()
    let sink = KaibaHandoverSink(client: client, instanceId: "kaiba-1", notebookId: "book-1")
    let ref = try await sink.write(packet, bytes: bytes, brief: "Readable brief")
    XCTAssertEqual(ref.locator, "kaiba-1/note-1")
    let readBytes = try await sink.read(ref)
    XCTAssertEqual(try HandoverSinkVerification.verify(bytes: readBytes, ref: ref), packet)
    let captured = await client.created()
    XCTAssertEqual(captured.title, "Handover handover-1 (task-1)")
    XCTAssertEqual(captured.notebookId, "book-1")
    XCTAssertEqual(captured.tags, ["riela-handover", "task:task-1"])
    XCTAssertTrue(captured.body.contains("Readable brief"))
    XCTAssertTrue(captured.body.contains("```riela-handover-packet\n"))
    let packetJSON = try XCTUnwrap(String(data: bytes, encoding: .utf8))
    XCTAssertTrue(captured.body.contains(packetJSON))
  }

  func testStoreSinkReadsCanonicalStorePacket() async throws {
    let store = WorkStore(rootDirectory: root.path)
    try store.saveTask(sampleTask())
    try store.saveHandover(packet)
    let sink = StoreHandoverSink(store: store, hostId: "host-1")
    let ref = try await sink.write(packet, bytes: bytes, brief: "unused")
    XCTAssertEqual(ref.locator, "host-1/task-1/handover-1")
    let readBytes = try await sink.read(ref)
    XCTAssertEqual(try HandoverSinkVerification.verify(bytes: readBytes, ref: ref), packet)
  }

  func testDigestVerificationAndSerializedReaderResolution() async throws {
    let file = FileHandoverSink(root: root.path)
    let ref = try await file.write(packet, bytes: bytes, brief: "brief")
    var altered = packet!
    altered.brief = "tampered"
    XCTAssertThrowsError(try HandoverSinkVerification.verify(bytes: JSONCanonical.encode(altered), ref: ref)) { error in
      guard case HandoverSinkError.digestMismatch = error else { return XCTFail("unexpected error: \(error)") }
    }
    let parsed = try HandoverSinkRef.parse(ref.serialized)
    XCTAssertEqual(parsed.kind, .file)
    let reader = try HandoverSinkFactory.reader(for: ref, context: sinkContext())
    let readBytes = try await reader.read(ref)
    XCTAssertEqual(readBytes, bytes)
  }

  func testFactoryMergesConfigsInOrderAndDeduplicatesByTarget() throws {
    let task = sampleTask(guardPolicy: GuardPolicy(handover: HandoverPolicy(sinks: [
      HandoverSinkConfig(kind: .kaiba, kaibaInstanceId: "k1"),
      HandoverSinkConfig(kind: .store),
      HandoverSinkConfig(kind: .file, path: root.path)
    ])))
    let workflow = WorkflowDefinition(workflowId: "flow", defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "entry", nodeRegistry: [], steps: [], nodes: [], handover: WorkflowHandoverDeclaration(sinks: [
        HandoverSinkConfig(kind: .kaiba, kaibaInstanceId: "k1"),
        HandoverSinkConfig(kind: .gitRef, remote: "origin")
      ]))
    let merged = HandoverSinkFactory.mergedConfigs(task: task, workflow: workflow, cliKinds: [.gitRef, .command])
    XCTAssertEqual(merged.map(\.kind), [.kaiba, .file, .gitRef, .command])
    XCTAssertThrowsError(try HandoverSinkFactory.make([HandoverSinkConfig(kind: .kaiba)], context: sinkContext()))
    XCTAssertThrowsError(try HandoverSinkFactory.make([HandoverSinkConfig(kind: .command)], context: sinkContext()))
  }

  private func samplePacket() -> HandoverPacket {
    HandoverPacket(
      id: HandoverID("handover-1"), taskId: TaskID("task-1"), intentId: IntentID("intent-1"),
      fromAttemptId: AttemptID("attempt-1"), fromSessionId: "session-1", generation: 1,
      reason: .userInputRequired(HandoverQuestion(id: "q1", text: "Proceed?")),
      workflow: HandoverWorkflowRef(workflowId: "flow", entryStepId: "start", resumeStepId: "resume"),
      progress: HandoverProgress(acceptedSteps: [], remainingSteps: ["resume"], latestGateResults: [], openFindings: [],
        evidenceSummary: [:], remainingBudget: BudgetSnapshot(attemptsUsed: 0, tokensUsed: 0, wallClockMsUsed: 0)),
      history: HandoverHistoryBundle(executions: [], messages: [], compatibilityDigests: [:], truncated: false),
      contract: HandoverContinuationContract(resumeStepId: "resume", completion: CompletionContract(), verification: [], guardPolicy: GuardPolicy()),
      brief: "Readable handover brief", producedBy: .runtime, producedOn: "host-1", createdAt: Date(timeIntervalSince1970: 1)
    )
  }

  private func sampleTask(guardPolicy: GuardPolicy = GuardPolicy()) -> WorkTask {
    WorkTask(id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "Test", instruction: "Test",
      plan: .workflow(WorkflowReference(name: "flow")), guardPolicy: guardPolicy)
  }

  private func sinkContext(repositoryRoot: String? = nil) -> HandoverSinkContext {
    HandoverSinkContext(hostId: "host-1", storeRoot: root.path, repositoryRoot: repositoryRoot,
      store: WorkStore(rootDirectory: root.path), environment: [:])
  }

  private func writeScript(_ contents: String) throws -> URL {
    let url = root.appendingPathComponent("fixture-\(UUID().uuidString).sh")
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }

  @discardableResult
  private func runGit(_ arguments: [String], cwd: URL) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    process.environment = hermeticGitEnvironment()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw HandoverSinkError.gitCommandFailed("test git command failed: \(arguments.joined(separator: " "))") }
    return String(bytes: data, encoding: .utf8) ?? ""
  }

  private func hermeticGitEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR"] {
      environment.removeValue(forKey: key)
    }
    environment["GIT_CEILING_DIRECTORIES"] = root.deletingLastPathComponent().path
    environment["GIT_TERMINAL_PROMPT"] = "0"
    return environment
  }

  private func assertTopLevelInsideFixture(_ repository: URL) throws {
    let output = try runGit(["rev-parse", "--show-toplevel"], cwd: repository)
    let topLevel = hermeticRealPath(URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines))).path
    let fixturePrefix = hermeticRealPath(root).path + "/"
    guard topLevel.hasPrefix(fixturePrefix) else {
      throw HandoverSinkError.gitCommandFailed("fixture repository top level \(topLevel) escaped \(fixturePrefix)")
    }
  }
}

private func hermeticRealPath(_ url: URL) -> URL {
  var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
  guard realpath(url.path, &buffer) != nil else { return url.standardizedFileURL }
  return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
}

private final class RecordingGitRunner: GitCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [GitCommandInvocation] = []

  func run(_ invocation: GitCommandInvocation) throws -> GitCommandResult {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(invocation)
    return GitCommandResult(exitCode: 128, output: "fatal: fake failure")
  }

  func invocations() -> [GitCommandInvocation] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
}

private struct CapturedKaibaNote: Sendable {
  let title: String
  let notebookId: String?
  let body: String
  let tags: [String]
}

private actor FakeKaibaHandoverNoteClient: KaibaHandoverNoteClient {
  private var body = ""
  private var details = CapturedKaibaNote(title: "", notebookId: nil, body: "", tags: [])

  func createNote(instanceId: String, notebookId: String?, title: String, bodyMarkdown: String, tags: [String]) async throws -> String {
    body = bodyMarkdown
    details = CapturedKaibaNote(title: title, notebookId: notebookId, body: bodyMarkdown, tags: tags)
    return "note-1"
  }

  func getNote(instanceId: String, noteId: String) async throws -> String { body }

  func created() -> CapturedKaibaNote { details }
}
