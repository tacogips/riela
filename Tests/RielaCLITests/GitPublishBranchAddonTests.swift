import Foundation
import RielaAdapters
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class GitPublishBranchAddonTests: XCTestCase {
  func testPublishRequiresRuntimeOwnedExecutionIdentity() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(publishInput(repository: repository, identity: nil), context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("runtime-owned execution identity") == true)
    }
  }

  func testPublishRejectsBranchOutsideAllowlist() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    let remoteBefore = try repository.git(["ls-remote", "--heads", "origin", "main"]).trimmed
    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(publishInput(repository: repository), context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("outside configured allowlist") == true)
    }
    XCTAssertEqual(try repository.git(["ls-remote", "--heads", "origin", "main"]).trimmed, remoteBefore)
  }

  func testPublishOutputAndUpToDateRepeat() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    try repository.git(["branch", "-m", "riela/task/T1/g1"])

    let published = try await repository.resolver.execute(publishInput(repository: repository), context: AdapterExecutionContext())
    let publishedEvidence = gitPayload(published.payload)
    let head = try repository.git(["rev-parse", "HEAD"]).trimmed
    XCTAssertEqual(publishedEvidence["operation"], .string("publish"))
    XCTAssertEqual(publishedEvidence["status"], .string("published"))
    XCTAssertEqual(publishedEvidence["pushedRemote"], .string("origin"))
    XCTAssertEqual(publishedEvidence["pushedBranch"], .string("riela/task/T1/g1"))
    XCTAssertEqual(publishedEvidence["created"], .bool(true))
    XCTAssertEqual(publishedEvidence["headCommit"], .string(head))

    let repeatPublish = try await repository.resolver.execute(publishInput(repository: repository), context: AdapterExecutionContext())
    XCTAssertEqual(gitPayload(repeatPublish.payload)["status"], .string("up-to-date"))
    XCTAssertEqual(gitPayload(repeatPublish.payload)["created"], .bool(false))
  }

  func testPublishBranchIsAllowedOnDistributedWorker() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    try repository.git(["branch", "-m", "riela/task/T2/g1"])
    let executor = DistributedWorkerNodeExecutor(
      workspaces: ["project": .init(root: repository.root)],
      adapter: DeterministicLocalNodeAdapter(),
      stdio: LocalWorkflowStdioNodeExecutor(),
      addons: repository.resolver,
      allowedAddons: [BuiltinGitAddon.publishBranch.rawValue]
    )
    let request = DistributedNodeRequest(
      invocation: .addon(publishInput(repository: repository)),
      workspace: "project",
      timeoutSeconds: 30
    )
    let payload = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(request))
    let result = try await executor.execute(.init(id: "publish-worker", target: .init(), payload: payload, status: .leased))
    XCTAssertEqual(result.outcome, .succeeded)
  }

  func testPublishRejectsUnknownConfiguration() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    let input = WorkflowAddonExecutionInput(
      workflowId: "git-publish-test",
      stepId: "publish",
      nodeId: "publish",
      addon: WorkflowNodeAddonRef(
        name: BuiltinGitAddon.publishBranch.rawValue,
        version: "1",
        config: ["unknown": .string("value")]
      ),
      executionIdentity: executionIdentity()
    )
    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(input, context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("unknown config keys") == true)
    }
  }

  private func publishInput(repository: GitTestRepository) -> WorkflowAddonExecutionInput {
    publishInput(repository: repository, identity: executionIdentity())
  }

  private func publishInput(
    repository _: GitTestRepository,
    identity: WorkflowAddonExecutionIdentity?
  ) -> WorkflowAddonExecutionInput {
    WorkflowAddonExecutionInput(
      workflowId: "git-publish-test",
      stepId: "publish",
      nodeId: "publish",
      addon: WorkflowNodeAddonRef(name: BuiltinGitAddon.publishBranch.rawValue, version: "1"),
      executionIdentity: identity
    )
  }

  private func executionIdentity() -> WorkflowAddonExecutionIdentity {
    WorkflowAddonExecutionIdentity(
      workflowExecutionId: "git-publish-test-execution",
      stepExecutionId: UUID().uuidString,
      attempt: 1
    )
  }
}
