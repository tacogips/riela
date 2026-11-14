import Foundation
import RielaCore
import RielaEvents
import RielaGraphQL
import RielaWorkflowRegistry
import XCTest
@testable import RielaCLI

final class RoutineCommandTests: XCTestCase {
  func testParsesRoutineCommands() throws {
    XCTAssertEqual(
      try RielaArgumentParser().parse([
        "routine", "create", "--name", "daily digest", "--task", "summarize", "--every", "30m",
        "--workflow", "routine-task-runner"
      ]),
      .scoped(ScopedCommand(
        kind: .routine,
        options: CLICommandOptions(
          scope: "routine",
          command: "create",
          target: nil,
          arguments: [
            "--name", "daily digest", "--task", "summarize", "--every", "30m",
            "--workflow", "routine-task-runner"
          ],
          output: .jsonl
        )
      ))
    )
    XCTAssertEqual(
      try RielaArgumentParser().parse(["routine", "complete", "routine-a", "--note", "done"]),
      .scoped(ScopedCommand(
        kind: .routine,
        options: CLICommandOptions(
          scope: "routine",
          command: "complete",
          target: "routine-a",
          arguments: ["--note", "done"],
          output: .jsonl
        )
      ))
    )
  }

  func testRoutineCreateListCompleteLifecycleThroughRunner() async throws {
    let workingDirectory = temporaryDirectory()
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    let runner = ScopedParityCommandRunner()

    let createResult = await runner.run(ScopedCommand(
      kind: .routine,
      options: CLICommandOptions(
        scope: "routine",
        command: "create",
        arguments: [
          "--name", "daily digest", "--task", "summarize inbox", "--every", "30m",
          "--workflow", "routine-task-runner", "--completion-criteria", "inbox empty",
          "--working-dir", workingDirectory.path
        ],
        output: .text
      )
    ))
    XCTAssertEqual(createResult.exitCode, .success, createResult.stderr)
    XCTAssertTrue(createResult.stdout.contains("status=active"), createResult.stdout)
    guard let routineId = createResult.stdout
      .split(separator: " ")
      .first(where: { $0.hasPrefix("routine=") })?
      .dropFirst("routine=".count)
    else {
      return XCTFail("routine id missing from create output: \(createResult.stdout)")
    }

    let service = RoutineService(workingDirectory: workingDirectory.path, environment: [:])
    let record = try service.get(routineId: String(routineId))
    XCTAssertEqual(record.schedule, "0 */30 * * * *")
    XCTAssertEqual(record.workflowName, "routine-task-runner")
    XCTAssertTrue(FileManager.default.fileExists(atPath: service.sourceFileURL(for: record).path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: service.bindingFileURL(for: record).path))
    let initialBinding = try JSONDecoder().decode(
      EventBindingContract.self,
      from: Data(contentsOf: service.bindingFileURL(for: record))
    )
    XCTAssertNil(initialBinding.overlapPolicy)
    XCTAssertNil(record.overlapPolicy)

    let completeResult = await runner.run(ScopedCommand(
      kind: .routine,
      options: CLICommandOptions(
        scope: "routine",
        command: "complete",
        target: String(routineId),
        arguments: ["--note", "all clear", "--working-dir", workingDirectory.path],
        output: .text
      )
    ))
    XCTAssertEqual(completeResult.exitCode, .success, completeResult.stderr)
    XCTAssertTrue(completeResult.stdout.contains("status=completed"), completeResult.stdout)

    let completed = try service.get(routineId: String(routineId))
    XCTAssertEqual(completed.status, .completed)
    XCTAssertEqual(completed.completionNote, "all clear")

    let inspectResult = await runner.run(ScopedCommand(
      kind: .routine,
      options: CLICommandOptions(
        scope: "routine", command: "inspect", target: String(routineId),
        arguments: ["--working-dir", workingDirectory.path], output: .text
      )
    ))
    XCTAssertTrue(inspectResult.stdout.contains("overlapPolicy=inherit"), inspectResult.stdout)

    let bindingData = try Data(contentsOf: service.bindingFileURL(for: completed))
    let binding = try JSONDecoder().decode(EventBindingContract.self, from: bindingData)
    XCTAssertFalse(binding.enabled)
  }

  func testRoutineCreateRejectsConflictingScheduleInputs() async throws {
    let workingDirectory = temporaryDirectory()
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    let result = await ScopedParityCommandRunner().run(ScopedCommand(
      kind: .routine,
      options: CLICommandOptions(
        scope: "routine",
        command: "create",
        arguments: [
          "--name", "x", "--task", "y", "--workflow", "z",
          "--schedule", "0 * * * * *", "--every", "30m",
          "--working-dir", workingDirectory.path
        ],
        output: .text
      )
    ))
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.contains("exactly one of schedule or every"), result.stderr)
  }

  func testRoutineOverlapPolicyCreateUpdateAndClearThroughRunner() async throws {
    let workingDirectory = temporaryDirectory()
    let eventRoot = workingDirectory.appendingPathComponent("events", isDirectory: true)
    let routineStore = workingDirectory.appendingPathComponent("routines", isDirectory: true)
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    let runner = ScopedParityCommandRunner()
    let createResult = await runner.run(ScopedCommand(
      kind: .routine,
      options: CLICommandOptions(
        scope: "routine",
        command: "create",
        arguments: [
          "--name", "policy routine", "--task", "run task", "--every", "30m",
          "--workflow", "routine-task-runner", "--event-root", eventRoot.path,
          "--routine-store", routineStore.path, "--overlap-policy", "queue", "--max-queued-runs", "2",
          "--working-dir", workingDirectory.path
        ],
        output: .text
      )
    ))
    XCTAssertEqual(createResult.exitCode, .success, createResult.stderr)
    let routineId = try XCTUnwrap(
      createResult.stdout.split(separator: " ")
        .first(where: { $0.hasPrefix("routine=") })?
        .dropFirst("routine=".count)
    )
    let service = RoutineService(workingDirectory: workingDirectory.path, environment: [:])
    let created = try service.get(routineId: String(routineId), routineStoreRoot: routineStore.path)
    var binding = try JSONDecoder().decode(
      EventBindingContract.self,
      from: Data(contentsOf: service.bindingFileURL(for: created))
    )
    XCTAssertEqual(binding.overlapPolicy, "queue")
    XCTAssertEqual(binding.maxQueuedRuns, 2)

    let inspectResult = await runner.run(ScopedCommand(
      kind: .routine,
      options: CLICommandOptions(
        scope: "routine", command: "inspect", target: String(routineId),
        arguments: ["--routine-store", routineStore.path, "--working-dir", workingDirectory.path],
        output: .text
      )
    ))
    XCTAssertEqual(inspectResult.exitCode, .success, inspectResult.stderr)
    XCTAssertTrue(inspectResult.stdout.contains("overlapPolicy=queue"), inspectResult.stdout)
    XCTAssertTrue(inspectResult.stdout.contains("maxQueuedRuns=2"), inspectResult.stdout)

    _ = try service.setStatus(
      routineId: String(routineId), status: .disabled, routineStoreRoot: routineStore.path
    )
    let updateResult = await runner.run(ScopedCommand(
      kind: .routine,
      options: CLICommandOptions(
        scope: "routine", command: "set-overlap-policy", target: String(routineId),
        arguments: [
          "--overlap-policy", "concurrent", "--max-concurrent-runs", "3",
          "--routine-store", routineStore.path, "--working-dir", workingDirectory.path
        ],
        output: .text
      )
    ))
    XCTAssertEqual(updateResult.exitCode, .success, updateResult.stderr)
    let updated = try service.get(routineId: String(routineId), routineStoreRoot: routineStore.path)
    XCTAssertEqual(updated.overlapPolicy, "concurrent")
    XCTAssertEqual(updated.maxConcurrentRuns, 3)
    binding = try JSONDecoder().decode(
      EventBindingContract.self,
      from: Data(contentsOf: service.bindingFileURL(for: updated))
    )
    XCTAssertFalse(binding.enabled)
    XCTAssertEqual(binding.overlapPolicy, "concurrent")
    XCTAssertEqual(binding.maxConcurrentRuns, 3)

    let clearResult = await runner.run(ScopedCommand(
      kind: .routine,
      options: CLICommandOptions(
        scope: "routine", command: "set-overlap-policy", target: String(routineId),
        arguments: [
          "--clear-overlap-policy", "--routine-store", routineStore.path,
          "--working-dir", workingDirectory.path
        ],
        output: .text
      )
    ))
    XCTAssertEqual(clearResult.exitCode, .success, clearResult.stderr)
    let cleared = try service.get(routineId: String(routineId), routineStoreRoot: routineStore.path)
    XCTAssertNil(cleared.overlapPolicy)
    XCTAssertNil(cleared.maxQueuedRuns)
    XCTAssertNil(cleared.maxConcurrentRuns)
    binding = try JSONDecoder().decode(
      EventBindingContract.self,
      from: Data(contentsOf: service.bindingFileURL(for: cleared))
    )
    XCTAssertFalse(binding.enabled)
    XCTAssertNil(binding.overlapPolicy)
    XCTAssertNil(binding.maxQueuedRuns)
    XCTAssertNil(binding.maxConcurrentRuns)
  }

  func testRoutineOverlapPolicyValidationAndUsageErrorsDoNotPersist() async throws {
    let workingDirectory = temporaryDirectory()
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    let eventRoot = workingDirectory.appendingPathComponent("events", isDirectory: true)
    let routineStore = workingDirectory.appendingPathComponent("routines", isDirectory: true)
    let runner = ScopedParityCommandRunner()
    let invalidCreate = await runner.run(ScopedCommand(
      kind: .routine,
      options: CLICommandOptions(
        scope: "routine", command: "create",
        arguments: [
          "--name", "invalid", "--task", "run task", "--every", "30m", "--workflow", "wf",
          "--event-root", eventRoot.path, "--routine-store", routineStore.path,
          "--overlap-policy", "bogus", "--working-dir", workingDirectory.path
        ],
        output: .text
      )
    ))
    XCTAssertEqual(invalidCreate.exitCode, .failure)
    XCTAssertTrue(invalidCreate.stderr.contains("overlapPolicy must be one of skip, cancelRunning, queue, concurrent; got 'bogus'"))
    XCTAssertEqual(try RoutineService(workingDirectory: workingDirectory.path, environment: [:])
      .list(routineStoreRoot: routineStore.path), [])

    let create = try RoutineService(workingDirectory: workingDirectory.path, environment: [:]).create(
      RoutineCreateRequest(
        name: "default", task: "run task", every: "30m", workflowName: "wf",
        eventRoot: eventRoot.path, routineStoreRoot: routineStore.path
      )
    )
    let record = create.routine
    let invalidUpdate = await runner.run(ScopedCommand(
      kind: .routine,
      options: CLICommandOptions(
        scope: "routine", command: "set-overlap-policy", target: record.routineId,
        arguments: [
          "--overlap-policy", "skip", "--max-queued-runs", "2",
          "--routine-store", routineStore.path, "--working-dir", workingDirectory.path
        ],
        output: .text
      )
    ))
    XCTAssertEqual(invalidUpdate.exitCode, .failure)
    XCTAssertTrue(invalidUpdate.stderr.contains("requires overlapPolicy queue"), invalidUpdate.stderr)
    XCTAssertEqual(try RoutineService(workingDirectory: workingDirectory.path, environment: [:])
      .get(routineId: record.routineId, routineStoreRoot: routineStore.path), record)

    let missingPolicy = await runner.run(ScopedCommand(
      kind: .routine,
      options: CLICommandOptions(
        scope: "routine", command: "set-overlap-policy", target: record.routineId,
        arguments: ["--routine-store", routineStore.path, "--working-dir", workingDirectory.path],
        output: .text
      )
    ))
    XCTAssertEqual(missingPolicy.exitCode, .failure)
    XCTAssertTrue(missingPolicy.stderr.contains("requires exactly one of --overlap-policy or --clear-overlap-policy"))

    let clearWithCap = await runner.run(ScopedCommand(
      kind: .routine,
      options: CLICommandOptions(
        scope: "routine", command: "set-overlap-policy", target: record.routineId,
        arguments: [
          "--clear-overlap-policy", "--max-queued-runs", "2",
          "--routine-store", routineStore.path, "--working-dir", workingDirectory.path
        ],
        output: .text
      )
    ))
    XCTAssertEqual(clearWithCap.exitCode, .failure)
    XCTAssertTrue(clearWithCap.stderr.contains("cannot be combined with a run cap"), clearWithCap.stderr)
    XCTAssertThrowsError(try RoutineService(workingDirectory: workingDirectory.path, environment: [:]).setOverlapPolicy(
      routineId: record.routineId, overlapPolicy: nil, maxQueuedRuns: 2, maxConcurrentRuns: nil,
      routineStoreRoot: routineStore.path
    )) { error in
      XCTAssertTrue(String(describing: error).contains("cannot be combined with a run cap"), String(describing: error))
    }
  }

  func testGraphQLExecutePreservesWorkflowAndRoutineRoots() async throws {
    let workingDirectory = temporaryDirectory()
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    let parsed = try ParsedParityOptions([
      "--query", "{ workflows { workflows { workflowId } } routines { routines { routineId } } }",
      "--working-dir", workingDirectory.path
    ])

    let output = try await ScopedParityCommandRunner().graphQLDocumentRecord(
      options: CLICommandOptions(scope: "graphql", command: "execute"),
      parsed: parsed,
      action: "execute"
    )
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
    )
    let data = try XCTUnwrap(object["data"] as? [String: Any])
    XCTAssertNotNil(data["workflows"])
    XCTAssertNotNil(data["routines"])
  }

  func testRoutineCreateRollsBackSourceWhenBindingWriteFails() throws {
    let workingDirectory = temporaryDirectory()
    let eventRoot = workingDirectory.appendingPathComponent("events", isDirectory: true)
    try FileManager.default.createDirectory(at: eventRoot, withIntermediateDirectories: true)
    try Data("not a directory".utf8).write(to: eventRoot.appendingPathComponent("bindings"))
    let service = RoutineService(workingDirectory: workingDirectory.path, environment: [:])

    XCTAssertThrowsError(try service.create(RoutineCreateRequest(
      name: "rollback",
      task: "test cleanup",
      every: "30m",
      workflowName: "routine-task-runner",
      eventRoot: eventRoot.path
    )))

    XCTAssertEqual(try service.list(), [])
    let sourceDirectory = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let sourceFiles = try FileManager.default.contentsOfDirectory(atPath: sourceDirectory.path)
    XCTAssertEqual(sourceFiles, [])
  }

  func testSetOverlapPolicyPreservesBindingFileEnabledStateAndHandEdits() throws {
    let workingDirectory = temporaryDirectory()
    let eventRoot = workingDirectory.appendingPathComponent("events", isDirectory: true)
    let routineStore = workingDirectory.appendingPathComponent("routines", isDirectory: true)
    let service = RoutineService(workingDirectory: workingDirectory.path, environment: [:])
    let record = try service.create(RoutineCreateRequest(
      name: "hand edited", task: "run task", every: "30m", workflowName: "wf",
      eventRoot: eventRoot.path, routineStoreRoot: routineStore.path
    )).routine
    XCTAssertEqual(record.status, .active)
    // The binding was disabled by hand (record still active) and its template edited.
    let bindingURL = service.bindingFileURL(for: record)
    guard case var .object(object) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: bindingURL)) else {
      return XCTFail("binding file is not an object")
    }
    object["enabled"] = .bool(false)
    object["note"] = .string("operator hand edit")
    try JSONEncoder().encode(JSONValue.object(object)).write(to: bindingURL)

    _ = try service.setOverlapPolicy(
      routineId: record.routineId, overlapPolicy: "queue", maxQueuedRuns: 3, maxConcurrentRuns: nil,
      routineStoreRoot: routineStore.path
    )
    let binding = try JSONDecoder().decode(EventBindingContract.self, from: Data(contentsOf: bindingURL))
    XCTAssertFalse(binding.enabled)
    XCTAssertEqual(binding.overlapPolicy, "queue")
    XCTAssertEqual(binding.maxQueuedRuns, 3)
    let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: bindingURL)) as? [String: Any])
    XCTAssertEqual(raw["note"] as? String, "operator hand edit")

    // Replacing the policy removes caps that the new call omits.
    _ = try service.setOverlapPolicy(
      routineId: record.routineId, overlapPolicy: "queue", maxQueuedRuns: nil, maxConcurrentRuns: nil,
      routineStoreRoot: routineStore.path
    )
    let replaced = try JSONDecoder().decode(EventBindingContract.self, from: Data(contentsOf: bindingURL))
    XCTAssertEqual(replaced.overlapPolicy, "queue")
    XCTAssertNil(replaced.maxQueuedRuns)
    XCTAssertNil(try service.get(routineId: record.routineId, routineStoreRoot: routineStore.path).maxQueuedRuns)
  }

  func testSetOverlapPolicyLeavesRecordUnchangedWhenBindingWriteFails() throws {
    let workingDirectory = temporaryDirectory()
    let eventRoot = workingDirectory.appendingPathComponent("events", isDirectory: true)
    let routineStore = workingDirectory.appendingPathComponent("routines", isDirectory: true)
    let service = RoutineService(workingDirectory: workingDirectory.path, environment: [:])
    let record = try service.create(RoutineCreateRequest(
      name: "write failure", task: "run task", every: "30m", workflowName: "wf",
      eventRoot: eventRoot.path, routineStoreRoot: routineStore.path
    )).routine
    // A directory where the binding file belongs makes the atomic write fail.
    let bindingURL = service.bindingFileURL(for: record)
    try FileManager.default.removeItem(at: bindingURL)
    try FileManager.default.createDirectory(
      at: bindingURL.appendingPathComponent("blocker", isDirectory: true), withIntermediateDirectories: true
    )

    XCTAssertThrowsError(try service.setOverlapPolicy(
      routineId: record.routineId, overlapPolicy: "concurrent", maxQueuedRuns: nil, maxConcurrentRuns: 2,
      routineStoreRoot: routineStore.path
    ))
    let unchanged = try service.get(routineId: record.routineId, routineStoreRoot: routineStore.path)
    XCTAssertNil(unchanged.overlapPolicy)
    XCTAssertNil(unchanged.maxConcurrentRuns)
  }

  func testRoutineOverlapPolicyThroughGraphQLFileProvider() async throws {
    let workingDirectory = temporaryDirectory()
    let eventRoot = workingDirectory.appendingPathComponent("events", isDirectory: true)
    let routineStore = workingDirectory.appendingPathComponent("routines", isDirectory: true)
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    let executor = RoutineGraphQLDocumentExecutor(
      provider: FileRoutineGraphQLProvider(workingDirectory: workingDirectory.path, environment: [:])
    )
    func execute(_ query: String) async -> JSONObject {
      await executor.execute(GraphQLDocumentRequest(
        query: query, variables: [:], operationName: nil, environment: [:], isLocallyTrusted: true
      )).body
    }
    let roots = "routineStoreRoot: \"\(routineStore.path)\""

    let created = await execute("""
    mutation {
      createRoutine(input: {name: "gql policy", task: "run", every: "30m", workflowName: "wf",
        eventRoot: "\(eventRoot.path)", \(roots), overlapPolicy: queue, maxQueuedRuns: 2}) {
        accepted
        routine { routineId overlapPolicy maxQueuedRuns }
      }
    }
    """)
    XCTAssertNil(created["errors"], "\(created)")
    guard case let .object(data)? = created["data"], case let .object(payload)? = data["createRoutine"],
          case let .object(routine)? = payload["routine"], case let .string(routineId)? = routine["routineId"] else {
      return XCTFail("unexpected createRoutine response: \(created)")
    }
    XCTAssertEqual(routine["overlapPolicy"], .string("queue"))
    XCTAssertEqual(routine["maxQueuedRuns"], .integer(2))
    let service = RoutineService(workingDirectory: workingDirectory.path, environment: [:])
    let record = try service.get(routineId: routineId, routineStoreRoot: routineStore.path)
    let bindingURL = service.bindingFileURL(for: record)
    var binding = try JSONDecoder().decode(EventBindingContract.self, from: Data(contentsOf: bindingURL))
    XCTAssertEqual(binding.overlapPolicy, "queue")
    XCTAssertEqual(binding.maxQueuedRuns, 2)

    let queried = await execute("""
    { routine(routineId: "\(routineId)", \(roots)) { routine { overlapPolicy maxQueuedRuns maxConcurrentRuns } } }
    """)
    guard case let .object(queryData)? = queried["data"], case let .object(queryPayload)? = queryData["routine"],
          case let .object(queriedRoutine)? = queryPayload["routine"] else {
      return XCTFail("unexpected routine response: \(queried)")
    }
    XCTAssertEqual(queriedRoutine["overlapPolicy"], .string("queue"))
    XCTAssertEqual(queriedRoutine["maxQueuedRuns"], .integer(2))

    let invalidCombination = await execute("""
    mutation { setRoutineOverlapPolicy(input: {routineId: "\(routineId)", \(roots), overlapPolicy: skip, maxQueuedRuns: 2}) { accepted } }
    """)
    XCTAssertTrue("\(invalidCombination["errors"] ?? .null)".contains("INVALID_ROUTINE"), "\(invalidCombination)")
    XCTAssertTrue("\(invalidCombination["errors"] ?? .null)".contains("requires overlapPolicy queue"), "\(invalidCombination)")

    let unknownValue = await execute("""
    mutation { setRoutineOverlapPolicy(input: {routineId: "\(routineId)", \(roots), overlapPolicy: bogus}) { accepted } }
    """)
    XCTAssertTrue("\(unknownValue["errors"] ?? .null)".contains("INVALID_ROUTINE"), "\(unknownValue)")
    XCTAssertEqual(try service.get(routineId: routineId, routineStoreRoot: routineStore.path).overlapPolicy, "queue")

    let cleared = await execute("""
    mutation { setRoutineOverlapPolicy(input: {routineId: "\(routineId)", \(roots), overlapPolicy: null}) { accepted routine { overlapPolicy } } }
    """)
    XCTAssertNil(cleared["errors"], "\(cleared)")
    binding = try JSONDecoder().decode(EventBindingContract.self, from: Data(contentsOf: bindingURL))
    XCTAssertNil(binding.overlapPolicy)
    XCTAssertNil(binding.maxQueuedRuns)
    XCTAssertNil(try service.get(routineId: routineId, routineStoreRoot: routineStore.path).overlapPolicy)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-routine-command-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }
}
