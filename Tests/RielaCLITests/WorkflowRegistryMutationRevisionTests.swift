import Foundation
import RielaCore
import RielaGraphQL
import RielaWorkflowRegistry
import XCTest

@MainActor
final class WorkflowRegistryMutationRevisionTests: XCTestCase {
  func testCoordinatedRegisterAndUpdateReturnStoredRevisionAndRejectStaleInput() async throws {
    let fixture = try await makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(fixture.environment) {
      let service = WorkflowRegistryService()
      let initial = try bundle("Initial", fixture: fixture)
      let replacement = try bundle("Replacement", fixture: fixture)
      let registered = try service.register(input: initial, overwrite: false, workingDirectory: fixture.root.path)
      let original = try storedData()
      let revision = try XCTUnwrap(registered.definitionRevision)
      XCTAssertEqual(revision.count, 64)
      XCTAssertEqual(revision, WorkflowHistoryCanonicalCoding.sha256(original))
      let workflow = try XCTUnwrap(registered.workflow)
      let target = WorkflowRegistryTarget(workflowId: workflow.workflowId, scope: .user, originId: workflow.originId)
      XCTAssertThrowsError(try service.update(
        target: target, input: replacement, expectedDefinitionRevision: "stale", workingDirectory: fixture.root.path
      )) { error in
        XCTAssertEqual((error as? WorkflowRegistryError)?.code, .registryConflict)
      }
      XCTAssertEqual(try storedData(), original)

      let updated = try service.update(
        target: target, input: replacement, expectedDefinitionRevision: revision, workingDirectory: fixture.root.path
      )
      XCTAssertTrue(updated.accepted)
      XCTAssertNotEqual(updated.definitionRevision, revision)
      XCTAssertEqual(updated.definitionRevision, WorkflowHistoryCanonicalCoding.sha256(try storedData()))
    }
  }

  func testDefinitionRevisionIsExcludedFromRegistryResultJSON() throws {
    let result = WorkflowRegistryMutationResult(accepted: true, definitionRevision: "revision")
    let encoded = try JSONEncoder().encode(result)
    var json = try JSONDecoder().decode(JSONObject.self, from: encoded)
    XCTAssertNil(json["definitionRevision"])
    XCTAssertEqual(json["accepted"], .bool(true))
    json["definitionRevision"] = .string("ignored")
    let decoded = try JSONDecoder().decode(WorkflowRegistryMutationResult.self, from: JSONEncoder().encode(json))
    XCTAssertNil(decoded.definitionRevision)
    XCTAssertTrue(decoded.accepted)
  }

  func testPlainProviderRejectsStaleRevisionWithoutChangingStoredBytes() async throws {
    let fixture = try await makeFixture()
    try await CLIRuntimeEnvironment.$overrides.withValue(fixture.environment) {
      let provider = FileWorkflowRegistryGraphQLProvider(workingDirectory: fixture.root.path)
      let initial = try bundle("Initial", fixture: fixture)
      let replacement = try bundle("Replacement", fixture: fixture)
      let registered = try await provider.registerMutableWorkflow(input: .init(), resolvedBundleURL: initial)
      let workflow = try XCTUnwrap(registered.workflow)
      let target = GraphQLWorkflowTargetInput(workflowId: workflow.workflowId, scope: .user, originId: workflow.originId)
      let original = try storedData()
      do {
        _ = try await provider.updateMutableWorkflow(
          input: .init(target: target, expectedDefinitionRevision: "stale"), resolvedBundleURL: replacement
        )
        XCTFail("Expected stale update to fail")
      } catch let error as WorkflowRegistryError {
        XCTAssertEqual(error.code, .registryConflict)
      }
      XCTAssertEqual(try storedData(), original)
    }
  }

  func testWebMutationPayloadsExposeRevisionAndKeepDefinitionPrivate() async throws {
    let fixture = try await makeFixture()
    try await CLIRuntimeEnvironment.$overrides.withValue(fixture.environment) {
      let provider = FileWorkflowRegistryGraphQLProvider(workingDirectory: fixture.root.path, webPrincipalId: "revision-test")
      let initial = try bundle("Initial", fixture: fixture)
      let replacement = try bundle("Replacement", fixture: fixture)
      let registered = try await provider.registerMutableWorkflow(input: .init(definition: [:]), resolvedBundleURL: initial)
      let workflow = try XCTUnwrap(registered.workflow)
      let target = GraphQLWorkflowTargetInput(workflowId: workflow.workflowId, scope: .user, originId: workflow.originId)
      let first = try await provider.workflow(target: target.registryTarget)
      let firstRevision = try XCTUnwrap(first.definitionRevision)
      XCTAssertNil(workflow.definition)
      XCTAssertEqual(workflow.definitionRevision, firstRevision)

      let updated = try await provider.updateMutableWorkflow(
        input: .init(target: target, definition: [:], expectedDefinitionRevision: firstRevision), resolvedBundleURL: replacement
      )
      let latest = try await provider.workflow(target: target.registryTarget)
      XCTAssertTrue(updated.accepted)
      XCTAssertNil(updated.workflow?.definition)
      XCTAssertNotEqual(latest.definitionRevision, firstRevision)
      XCTAssertEqual(updated.workflow?.definitionRevision, try XCTUnwrap(latest.definitionRevision))
    }
  }

  private func makeFixture() async throws -> AskToolFixture {
    try await AskToolFixture(test: self, evidencePlan: "ask-06-workflow-authoring")
  }

  private func bundle(_ description: String, fixture: AskToolFixture) throws -> URL {
    let root = fixture.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var definition = AskWorkflowAuthoringTests.definition
    definition["description"] = .string(description)
    try JSONEncoder().encode(definition).write(to: root.appendingPathComponent("workflow.json"))
    return root
  }

  private func storedData() throws -> Data {
    try Data(contentsOf: WorkflowMutableRegistry().root.appendingPathComponent("authored-workflow/workflow.json"))
  }
}
