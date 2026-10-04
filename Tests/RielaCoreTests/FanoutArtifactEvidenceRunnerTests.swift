import Foundation
import XCTest
@testable import RielaCore

/// Issue #130: a plan-local tool directory that is empty at dispatch, grows past
/// the source snapshot limits during an implementation node, and must still be
/// observable at the next node boundary and at parent reduction.
final class FanoutArtifactEvidenceRunnerTests: XCTestCase {
  func testEmptyAtDispatchToolDirectoryCompletesUnderArtifactContract() async throws {
    let root = try scratch()
    try Data("# docs".utf8).write(to: root.appendingPathComponent("README.md"))
    let adapter = ArtifactFanoutAdapter(root: root, items: artifactItems(classified: true))
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter, fanoutWorkspaceRoot: root)

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: artifactFanoutWorkflow(failurePolicy: .collectPartial, classifyArtifacts: true),
      nodePayloads: artifactPayloads()
    ))

    XCTAssertEqual(result.status, .completed)
    let capturedJoin = await adapter.capturedJoin()
    let join = try XCTUnwrap(capturedJoin)
    XCTAssertEqual(join["allBranchesCompleted"], .bool(true))
    XCTAssertEqual(branchStatuses(join), ["completed", "completed"])
    guard case let .object(evidence)? = join["changeEvidence"] else { return XCTFail("missing changeEvidence") }
    XCTAssertEqual(evidence["complete"], .bool(true))
    XCTAssertEqual(evidence["reduceFailures"], .array([]))
    XCTAssertEqual(evidence["captureFailures"], .array([]))
    assertObservation(evidence, branch: "pkg", path: "tools", selection: "artifact", reason: "entry-added")
    assertObservation(evidence, branch: "pkg", path: "tools/toolchain.json", selection: "source", reason: "entry-added")
    XCTAssertFalse((String(data: try JSONEncoder().encode(evidence), encoding: .utf8) ?? "").contains("contentBase64"))

    // The after-install record identifies the tool tree without copying it.
    guard case let .array(artifactPaths)? = evidence["artifactPaths"] else { return XCTFail("missing artifactPaths") }
    let afterInstall = try artifactPaths.compactMap { value -> JSONObject? in
      guard case let .string(path) = value else { return nil }
      let record = try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
      return record["stepId"] == .string("after:install") && record["branchId"] == .string("pkg") ? record : nil
    }
    XCTAssertEqual(afterInstall.count, 1)
    let record = try XCTUnwrap(afterInstall.first)
    XCTAssertEqual(fanoutJSONPointer(.object(record), "/artifacts/tools/kind"), .string("directory"))
    XCTAssertEqual(fanoutJSONPointer(.object(record), "/artifacts/tools/entryCount"), .integer(Int64(ArtifactFanoutAdapter.cacheEntries + 4)))
    XCTAssertEqual(fanoutJSONPointer(.object(record), "/artifacts/tools/scanTruncated"), .bool(false))
    XCTAssertEqual(fanoutJSONPointer(.object(record), "/summary/sourceEntries"), .integer(2))
    guard case let .object(files)? = record["files"] else { return XCTFail("missing files") }
    XCTAssertEqual(Set(files.keys), ["src/pkg.rs", "tools/toolchain.json"])
    XCTAssertNotNil(fanoutJSONPointer(.object(record), "/files/tools~1toolchain.json/contentBase64"))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("tools/cache").path).count,
                   ArtifactFanoutAdapter.cacheEntries, "installation output is preserved")
  }

  func testUnclassifiedGrowthFailsTheBranchWithStructuredDiagnosticsAndKeepsSiblingEvidence() async throws {
    let root = try scratch()
    try Data("# docs".utf8).write(to: root.appendingPathComponent("README.md"))
    let adapter = ArtifactFanoutAdapter(root: root, items: artifactItems(classified: false))
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter, fanoutWorkspaceRoot: root)

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: artifactFanoutWorkflow(failurePolicy: .collectPartial, classifyArtifacts: true),
      nodePayloads: artifactPayloads()
    ))

    XCTAssertEqual(result.status, .completed, "collect-partial still delivers the join")
    let capturedJoin = await adapter.capturedJoin()
    let join = try XCTUnwrap(capturedJoin)
    XCTAssertEqual(join["allBranchesCompleted"], .bool(false))
    XCTAssertEqual(branchStatuses(join), ["failed", "completed"])
    guard case let .array(branches)? = join["branches"], case let .object(failed) = branches[0],
          case let .string(reason)? = failed["failureReason"] else {
      return XCTFail("failed branch should carry a failureReason")
    }
    XCTAssertTrue(reason.hasPrefix("policy_blocked: fanout snapshot exceeds 512 entries [branch=pkg node=install phase=after-node selection=source root=tools path=tools/cache/"), reason)
    XCTAssertTrue(reason.hasSuffix("observed=513 limit=512]"), reason)
    XCTAssertFalse(reason.contains("contentBase64"))
    let reviewed = await adapter.reviewedBranches()
    XCTAssertEqual(reviewed, ["docs"], "the review node never runs after the install boundary rejects the snapshot")

    guard case let .object(evidence)? = join["changeEvidence"] else { return XCTFail("missing changeEvidence") }
    XCTAssertEqual(evidence["complete"], .bool(false))
    guard case let .array(captureFailures)? = evidence["captureFailures"], case let .object(captureFailure)? = captureFailures.first else {
      return XCTFail("the child's boundary failure must survive as evidence")
    }
    XCTAssertEqual(captureFailure["branchId"], .string("pkg"))
    XCTAssertEqual(captureFailure["node"], .string("install"))
    XCTAssertEqual(captureFailure["phase"], .string("after-node"))
    XCTAssertEqual(captureFailure["root"], .string("tools"))
    XCTAssertEqual(captureFailure["observed"], .integer(513))
    XCTAssertEqual(captureFailure["limit"], .integer(512))
    guard case let .array(reduceFailures)? = evidence["reduceFailures"], !reduceFailures.isEmpty else {
      return XCTFail("parent reduction over the grown tree must be reported, not thrown")
    }
    for value in reduceFailures {
      guard case let .object(failure) = value else { return XCTFail("reduce failure must be an object") }
      XCTAssertEqual(failure["branchId"], .string("pkg"))
      XCTAssertEqual(failure["phase"], .string("reduce"))
      XCTAssertEqual(failure["root"], .string("tools"))
      XCTAssertEqual(failure["code"], .string("policy_blocked"))
      XCTAssertEqual(failure["limit"], .integer(512))
    }
    // Sibling evidence is intact: the docs branch reduced normally and drift on its root is attributed to it.
    assertObservation(evidence, branch: "docs", path: "README.md", selection: "source", reason: "content-or-mode-drift")
    XCTAssertFalse(observations(evidence).contains { $0["branchId"] == .string("docs") && $0["path"] == .string("tools") })
  }

  func testFailFastTreatsReduceFailureAsFanoutFailure() async throws {
    let root = try scratch()
    try Data("# docs".utf8).write(to: root.appendingPathComponent("README.md"))
    // Branches run one at a time in input order. The pkg branch completes with
    // `tools` still empty; the later docs branch installs the tool, so only the
    // parent reduction over the final tree exceeds the pkg source limit.
    let adapter = ArtifactFanoutAdapter(root: root, items: artifactItems(classified: false), growth: ("docs", "install"))
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter, fanoutWorkspaceRoot: root)

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: artifactFanoutWorkflow(failurePolicy: .failFast, classifyArtifacts: false),
        nodePayloads: artifactPayloads()
      ))
      XCTFail("fail-fast must not accept incomplete change evidence")
    } catch DeterministicWorkflowRunnerError.fanoutDispatchFailed(let groupId, let reason) {
      XCTAssertEqual(groupId, "tool-install")
      XCTAssertTrue(reason.contains("fanout change evidence reduction failed: fanout snapshot exceeds 512 entries [branch=pkg"), reason)
      XCTAssertTrue(reason.contains("phase=reduce selection=source root=tools path=tools/cache/"), reason)
    }
  }

  func testDispatchPreflightFailureSurfacesAsGroupScopedFanoutError() async throws {
    let root = try scratch()
    try Data("# docs".utf8).write(to: root.appendingPathComponent("README.md"))
    var items = artifactItems(classified: true)
    // pathsFrom must resolve to an array; a scalar is rejected before any branch runs.
    items[0] = .object([
      "planId": .string("pkg"), "dependsOn": .array([]),
      "trackedPaths": .string("src/pkg.rs"), "artifactRoots": .array([])
    ])
    let adapter = ArtifactFanoutAdapter(root: root, items: items)
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter, fanoutWorkspaceRoot: root)

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: artifactFanoutWorkflow(failurePolicy: .collectPartial, classifyArtifacts: true),
        nodePayloads: artifactPayloads()
      ))
      XCTFail("a preflight selection failure must fail the dispatch")
    } catch DeterministicWorkflowRunnerError.fanoutDispatchFailed(let groupId, let reason) {
      XCTAssertEqual(groupId, "tool-install")
      XCTAssertTrue(
        reason.hasPrefix("fanout dispatch preflight failed: invalid_output: fanout changeTracking.pathsFrom must resolve to an array"),
        reason
      )
    }
    let reviewed = await adapter.reviewedBranches()
    XCTAssertEqual(reviewed, [], "no branch runs after a failed preflight")
  }

  func testNoOpDispatchCreatesNoEvidenceDirectory() async throws {
    let root = try scratch()
    let adapter = ArtifactFanoutAdapter(root: root, items: [])
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter, fanoutWorkspaceRoot: root)

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: artifactFanoutWorkflow(failurePolicy: .collectPartial, classifyArtifacts: true),
      nodePayloads: artifactPayloads()
    ))

    XCTAssertEqual(result.status, .completed)
    let capturedJoin = await adapter.capturedJoin()
    let join = try XCTUnwrap(capturedJoin)
    XCTAssertEqual(join["allBranchesCompleted"], .bool(true))
    XCTAssertEqual(join["dispatchedBranchIds"], .array([]))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("tmp/riela-fanout").path),
      "a no-op dispatch must not create an empty evidence directory"
    )
  }

  // MARK: - Helpers

  /// Classified: the authored audit file stays a source snapshot and the tool
  /// directory is an artifact root. Unclassified: the whole tool directory is a
  /// source snapshot root, which is the contract that failed in issue #130.
  private func artifactItems(classified: Bool) -> [JSONValue] {
    [
      .object([
        "planId": .string("pkg"), "dependsOn": .array([]),
        "trackedPaths": .array([.string("src/pkg.rs"), .string(classified ? "tools/toolchain.json" : "tools")]),
        "artifactRoots": .array(classified ? [.string("tools")] : [])
      ]),
      .object([
        "planId": .string("docs"), "dependsOn": .array([]),
        "trackedPaths": .array([.string("README.md")]),
        "artifactRoots": .array([])
      ])
    ]
  }

  private func branchStatuses(_ join: JSONObject) -> [String?] {
    guard case let .array(branches)? = join["branches"] else { return [] }
    return branches.map { branch -> String? in
      guard case let .object(record) = branch, case let .string(status)? = record["status"] else { return nil }
      return status
    }
  }

  private func observations(_ evidence: JSONObject) -> [JSONObject] {
    guard case let .array(values)? = evidence["observations"] else { return [] }
    return values.compactMap { value -> JSONObject? in
      guard case let .object(item) = value else { return nil }
      return item
    }
  }

  private func assertObservation(_ evidence: JSONObject, branch: String, path: String, selection: String, reason: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(observations(evidence).contains {
      $0["branchId"] == .string(branch) && $0["path"] == .string(path) && $0["selection"] == .string(selection) && $0["reason"] == .string(reason)
    }, "missing \(branch):\(path):\(selection):\(reason)", file: file, line: line)
  }

  private func scratch() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/fanout-artifact-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    try Data("pub fn pkg() {}".utf8).write(to: root.appendingPathComponent("src/pkg.rs"))
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root
  }
}

private actor ArtifactFanoutAdapter: NodeAdapter {
  static let cacheEntries = 600
  private let root: URL
  private let items: [JSONValue]
  private let growth: (planId: String, node: String)
  private var join: JSONObject?
  private var reviewed: [String] = []

  init(root: URL, items: [JSONValue], growth: (planId: String, node: String) = ("pkg", "install")) {
    self.root = root
    self.items = items
    self.growth = growth
  }

  func capturedJoin() -> JSONObject? { join }
  func reviewedBranches() -> [String] { reviewed.sorted() }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    let planId: String
    if case let .object(item)? = input.arguments["implementation"], case let .string(id)? = item["planId"] {
      planId = id
    } else {
      planId = "none"
    }
    switch input.node.id {
    case "source":
      return output(input, payload: ["payload": .object(["items": .array(items)])])
    case "install", "review":
      if input.node.id == "review" { reviewed.append(planId) }
      if input.node.id == "install" {
        if planId == growth.planId, input.node.id == growth.node {
          try installTool()
        } else if planId == "docs" {
          try Data("# docs edited by \(planId)".utf8).write(to: root.appendingPathComponent("README.md"))
        }
      }
      return output(input, payload: ["status": .string("\(input.node.id)-ok"), "planId": .string(planId)])
    case "join":
      if case let .object(runtimeVariables)? = input.mergedVariables["runtimeVariables"],
         case let .object(fanoutJoin)? = runtimeVariables["fanoutJoin"] {
        join = fanoutJoin
      } else if case let .object(fanoutJoin)? = input.mergedVariables["fanoutJoin"] {
        join = fanoutJoin
      }
      return output(input, payload: ["joined": .bool(true)])
    default:
      throw AdapterExecutionError(.invalidInput, "unexpected step '\(input.node.id)'")
    }
  }

  /// Simulates an authorized, successful tool installation: a task-local
  /// registry cache with hundreds of entries, a binary above the source
  /// per-file limit, a symlinked launcher and a small audit manifest.
  private func installTool() throws {
    let tools = root.appendingPathComponent("tools")
    let cache = tools.appendingPathComponent("cache")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    for index in 0..<Self.cacheEntries {
      try Data("crate \(index)".utf8).write(to: cache.appendingPathComponent(String(format: "crate-%04d.crate", index)))
    }
    try Data(count: 9_000_000).write(to: tools.appendingPathComponent("tool-bin"))
    try FileManager.default.createSymbolicLink(at: tools.appendingPathComponent("tool"), withDestinationURL: tools.appendingPathComponent("tool-bin"))
    try Data(#"{"tool":"1.2.3","exit":0}"#.utf8).write(to: tools.appendingPathComponent("toolchain.json"))
  }

  private func output(_ input: AdapterExecutionInput, payload: JSONObject) -> AdapterExecutionOutput {
    AdapterExecutionOutput(provider: "test", model: input.node.model, promptText: input.promptText, completionPassed: true, payload: payload)
  }
}

private func artifactFanoutWorkflow(failurePolicy: WorkflowFanoutFailurePolicy, classifyArtifacts: Bool) -> WorkflowDefinition {
  WorkflowDefinition(
    workflowId: "fanout-artifact-evidence",
    defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
    entryStepId: "source",
    nodeRegistry: [
      WorkflowNodeRegistryRef(id: "source-node", nodeFile: "nodes/source.json"),
      WorkflowNodeRegistryRef(id: "install-node", nodeFile: "nodes/install.json"),
      WorkflowNodeRegistryRef(id: "review-node", nodeFile: "nodes/review.json"),
      WorkflowNodeRegistryRef(id: "join-node", nodeFile: "nodes/join.json")
    ],
    steps: [
      WorkflowStepRef(
        id: "source",
        nodeId: "source-node",
        transitions: [
          WorkflowStepTransition(
            toStepId: "install",
            fanout: WorkflowStepFanout(
              groupId: "tool-install",
              itemsFrom: "/payload/items",
              itemVariable: "implementation",
              concurrency: 1,
              joinStepId: "join",
              failurePolicy: failurePolicy,
              resultOrder: .input,
              writeOwnership: WorkflowFanoutWriteOwnership(mode: .sharedWorkspace),
              dependencies: WorkflowFanoutDependencies(branchIdFrom: "/planId", dependsOnFrom: "/dependsOn"),
              changeTracking: WorkflowFanoutChangeTracking(
                pathsFrom: "/trackedPaths",
                artifactRootsFrom: classifyArtifacts ? "/artifactRoots" : nil
              )
            )
          )
        ]
      ),
      WorkflowStepRef(id: "install", nodeId: "install-node", transitions: [WorkflowStepTransition(toStepId: "review")]),
      WorkflowStepRef(id: "review", nodeId: "review-node", transitions: [WorkflowStepTransition(toStepId: "join")]),
      WorkflowStepRef(id: "join", nodeId: "join-node")
    ],
    nodes: [
      WorkflowNodeRef(id: "source-node", nodeFile: "nodes/source.json"),
      WorkflowNodeRef(id: "install-node", nodeFile: "nodes/install.json"),
      WorkflowNodeRef(id: "review-node", nodeFile: "nodes/review.json"),
      WorkflowNodeRef(id: "join-node", nodeFile: "nodes/join.json")
    ]
  )
}

private func artifactPayloads() -> [String: AgentNodePayload] {
  Dictionary(uniqueKeysWithValues: ["source-node", "install-node", "review-node", "join-node"].map { id in
    (id, AgentNodePayload(id: id, executionBackend: .codexAgent, model: "gpt-5.5", agentSandbox: .readOnly))
  })
}
