import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore

func makeWorkflowVersioningFixture(_ testCase: XCTestCase) async throws -> (URL, WorkflowCreateCommandResult) {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("riela-version-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  testCase.addTeardownBlock { removeWorkflowVersioningTestDirectory(root) }
  let response = await RielaCLIApplication().run([
    "workflow", "create", "versioned-flow",
    "--working-dir", root.path,
    "--output", "json"
  ])
  XCTAssertEqual(response.exitCode, .success, response.stderr)
  let created = try JSONDecoder().decode(WorkflowCreateCommandResult.self, from: Data(response.stdout.utf8))
  try configureVersioningReviewGate(workflowDirectory: created.workflowDirectory)
  return (root, created)
}

private func configureVersioningReviewGate(workflowDirectory: String) throws {
  let url = URL(fileURLWithPath: workflowDirectory).appendingPathComponent("workflow.json")
  var workflow = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
  var steps = workflow["steps"] as? [[String: Any]] ?? []
  guard !steps.isEmpty, let stepId = steps[0]["id"] as? String else {
    throw CLIUsageError("versioning fixture requires a workflow step")
  }
  steps[0]["loop"] = ["role": "gate", "gateId": "review-gate"]
  workflow["steps"] = steps
  workflow["loop"] = [
    "required": true,
    "gates": [[
      "id": "review-gate",
      "stepId": stepId,
      "required": true,
      "acceptWhen": ["decision": "accepted", "maxHighFindings": 0, "maxMediumFindings": 0]
    ]],
    "selfEvolution": [
      "allowed": true,
      "defaultMode": "propose",
      "requiresReviewGate": true,
      "snapshotPolicy": "bundle-before-apply",
      "historyRoot": ".riela/workflow-history",
      "immutablePackageMutation": "deny",
      "requiredVerification": ["workflow validate"]
    ]
  ]
  try JSONSerialization.data(withJSONObject: workflow, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

struct WorkflowVersioningResolvedTarget {
  var bundle: ResolvedWorkflowBundle
  var identity: WorkflowBundleIdentity
  var historyRoot: URL
}

struct MutableWorkflowVersioningFixture {
  var root: URL
  var created: WorkflowCreateCommandResult
  var environment: [String: String]
  var resolved: WorkflowVersioningResolvedTarget

  var workflowDirectory: URL {
    URL(fileURLWithPath: resolved.identity.ownershipRoot, isDirectory: true)
  }

  func registeredURL(for sourcePath: String) throws -> URL {
    let sourceRoot = URL(fileURLWithPath: created.workflowDirectory, isDirectory: true)
      .standardizedFileURL.path
    let source = URL(fileURLWithPath: sourcePath).standardizedFileURL.path
    let prefix = sourceRoot + "/"
    guard source.hasPrefix(prefix) else {
      throw CLIUsageError("versioning fixture source path is outside the created workflow")
    }
    return workflowDirectory.appendingPathComponent(String(source.dropFirst(prefix.count)))
  }
}

func resolveVersioningTarget(root: URL) throws -> WorkflowVersioningResolvedTarget {
  let bundle = try FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(
    workflowName: "versioned-flow",
    scope: .project,
    workingDirectory: root.path
  ))
  let target = try WorkflowHistoryIdentityResolver.identity(for: bundle)
  let historyRoot = try WorkflowHistoryIdentityResolver.historyRoot(for: target, workingDirectory: root)
  return WorkflowVersioningResolvedTarget(bundle: bundle, identity: target, historyRoot: historyRoot)
}

func resolveMutableTransactionTarget(root: URL) throws -> WorkflowVersioningResolvedTarget {
  let environment = mutableWorkflowVersioningEnvironment(root: root)
  let home = URL(fileURLWithPath: environment["HOME"] ?? "", isDirectory: true)
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  return try CLIRuntimeEnvironment.$overrides.withValue(environment) {
    let input = root.appendingPathComponent(".riela/workflows/versioned-flow", isDirectory: true)
    let destination = home.appendingPathComponent(
      ".riela/temporary-workflows/versioned-flow",
      isDirectory: true
    )
    if !FileManager.default.fileExists(atPath: destination.path) {
      _ = try WorkflowMutableRegistry().register(input: input, overwrite: false)
    }
    let bundle = try FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(
      workflowName: "versioned-flow",
      scope: .user,
      workingDirectory: root.path
    ))
    let target = try WorkflowHistoryIdentityResolver.identity(for: bundle)
    let historyRoot = try WorkflowHistoryIdentityResolver.historyRoot(
      for: target,
      workingDirectory: root
    )
    return WorkflowVersioningResolvedTarget(
      bundle: bundle,
      identity: target,
      historyRoot: historyRoot
    )
  }
}

func makeMutableWorkflowVersioningFixture(
  _ testCase: XCTestCase
) async throws -> MutableWorkflowVersioningFixture {
  let (root, created) = try await makeWorkflowVersioningFixture(testCase)
  return MutableWorkflowVersioningFixture(
    root: root,
    created: created,
    environment: mutableWorkflowVersioningEnvironment(root: root),
    resolved: try resolveMutableTransactionTarget(root: root)
  )
}

func mutableWorkflowVersioningEnvironment(root: URL) -> [String: String] {
  ["HOME": root.appendingPathComponent("mutable-home", isDirectory: true).path]
}

func decodeVersionJSON<T: Decodable>(_ type: T.Type, _ output: String) throws -> T {
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  return try decoder.decode(type, from: Data(output.utf8))
}

func removeWorkflowVersioningTestDirectory(_ root: URL) {
  guard FileManager.default.fileExists(atPath: root.path) else { return }
  if let enumerator = FileManager.default.enumerator(
    at: root,
    includingPropertiesForKeys: [.isDirectoryKey]
  ) {
    var directories = [root]
    for case let url as URL in enumerator {
      if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        directories.append(url)
      } else {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
      }
    }
    for directory in directories.reversed() {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    }
  }
  try? FileManager.default.removeItem(at: root)
}
