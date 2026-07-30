#if os(macOS)
import Foundation
import RielaCLI
import RielaCore
import RielaGraphQL
import XCTest

final class RielaAppWebRegistryProviderTests: XCTestCase {
  func testSharedProviderPreservesBundleAndCanonicalActivationDuringWebCRUD() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": home.path]) {
      let provider = webProvider()
      let initial = try makeBundle(description: "Initial", includeNode: true)
      defer { try? FileManager.default.removeItem(at: initial) }

      let registered = try await provider.registerMutableWorkflow(
        input: GraphQLRegisterMutableWorkflowInput(definition: [:], activationState: .active),
        resolvedBundleURL: initial
      )
      let entry = try await detail(provider: provider, mutation: registered)
      XCTAssertEqual(entry.workflowId, "web-registry-test")
      XCTAssertEqual(entry.activationState, "ACTIVE")
      XCTAssertEqual(entry.definitionRevision?.count, 64)
      XCTAssertNil(registered.workflow?.definition)
      XCTAssertNil(registered.workflow?.definitionRevision)

      let replacement = try makeBundle(description: "Updated", includeNode: false)
      defer { try? FileManager.default.removeItem(at: replacement) }
      let target = exactTarget(entry)
      let updated = try await provider.updateMutableWorkflow(
        input: GraphQLUpdateMutableWorkflowInput(
          target: target,
          definition: [:],
          expectedDefinitionRevision: entry.definitionRevision
        ),
        resolvedBundleURL: replacement
      )
      XCTAssertEqual(updated.workflow?.description, "Updated")
      let updatedEntry = try await detail(provider: provider, mutation: updated)
      XCTAssertTrue(FileManager.default.fileExists(
        atPath: home.appendingPathComponent(
          ".riela/temporary-workflows/web-registry-test/nodes/main.json"
        ).path
      ))

      let deactivated = try await provider.setWorkflowActivation(
        input: GraphQLSetWorkflowActivationInput(
          target: exactTarget(updatedEntry),
          expectedDefinitionRevision: updatedEntry.definitionRevision,
          expectedActivationState: .active
        ),
        state: .deactivated
      )
      XCTAssertEqual(deactivated.workflow?.activationState, "DEACTIVATED")
      let activationState = try Data(contentsOf: home.appendingPathComponent(
        ".riela/workflow-state/activation.json"
      ))
      XCTAssertTrue(try XCTUnwrap(String(data: activationState, encoding: .utf8)).contains(entry.originId))
      let deactivatedEntries = try await provider.workflows(filter: WorkflowRegistryFilter())
      let deactivatedEntry = try XCTUnwrap(deactivatedEntries.first)
      XCTAssertEqual(deactivatedEntry.activationState, "DEACTIVATED")
      XCTAssertNil(deactivatedEntry.definition)
      XCTAssertNil(deactivatedEntry.definitionRevision)
      let deactivatedDetail = try await provider.workflow(
        target: WorkflowRegistryTarget(
          workflowId: deactivatedEntry.workflowId,
          scope: .user,
          originId: deactivatedEntry.originId
        )
      )

      let deleted = try await provider.deleteMutableWorkflow(input: GraphQLDeleteMutableWorkflowInput(
        target: exactTarget(deactivatedDetail),
        expectedDefinitionRevision: deactivatedDetail.definitionRevision
      ))
      XCTAssertTrue(deleted.accepted)
      let remaining = try await provider.workflows(filter: WorkflowRegistryFilter())
      XCTAssertTrue(remaining.isEmpty)
    }
  }

  func testRegistrationRejectsIncompleteBundle() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": home.path]) {
      let bundle = try makeBundle(description: "Incomplete", includeNode: false)
      defer { try? FileManager.default.removeItem(at: bundle) }
      await assertRegistryError(.invalidWorkflow) {
        _ = try await self.webProvider().registerMutableWorkflow(
          input: GraphQLRegisterMutableWorkflowInput(definition: [:]),
          resolvedBundleURL: bundle
        )
      }
    }
  }

  func testRetainHandlesRejectForgeryMovementAndCrossPrincipalReplay() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": home.path]) {
      let key = Data(repeating: 0x5a, count: 32)
      let provider = webProvider(principalId: "principal-a", retainKey: key)
      let initial = try makeBundle(description: "Initial", includeNode: true, includeSecretMetadata: true)
      defer { try? FileManager.default.removeItem(at: initial) }
      let registered = try await provider.registerMutableWorkflow(
        input: GraphQLRegisterMutableWorkflowInput(definition: [:]),
        resolvedBundleURL: initial
      )
      let entry = try await detail(provider: provider, mutation: registered)
      let target = exactTarget(entry)
      let definition = try XCTUnwrap(entry.definition)
      let persistedURL = home.appendingPathComponent(
        ".riela/temporary-workflows/web-registry-test/workflow.json"
      )
      let originalData = try Data(contentsOf: persistedURL)
      let retained = try XCTUnwrap(definition["metadata"])
      let projectedText = try XCTUnwrap(String(
        data: try JSONEncoder().encode(JSONValue.object(definition)),
        encoding: .utf8
      ))
      XCTAssertFalse(projectedText.contains("SECRET_CANARY_VALUE"))
      guard case let .object(retainObject) = retained,
            case let .string(handle)? = retainObject["$rielaRetain"] else {
        return XCTFail("Expected an opaque retain handle")
      }
      XCTAssertFalse(handle.contains(":"))

      try await assertRejectedUpdate(
        provider: provider,
        target: target,
        revision: entry.definitionRevision,
        definition: definition.merging(["metadata": .object(["$rielaRetain": .string("forged")])]) { _, new in new },
        expectedCode: .invalidWorkflow
      )
      try await assertRejectedUpdate(
        provider: provider,
        target: target,
        revision: entry.definitionRevision,
        definition: definition.merging(["description": retained]) { _, new in new },
        expectedCode: .invalidWorkflow
      )
      try await assertRejectedUpdate(
        provider: webProvider(principalId: "principal-b", retainKey: key),
        target: target,
        revision: entry.definitionRevision,
        definition: definition,
        expectedCode: .invalidWorkflow
      )
      XCTAssertEqual(try Data(contentsOf: persistedURL), originalData)
      let acceptedRoot = try definitionBundle(definition)
      defer { try? FileManager.default.removeItem(at: acceptedRoot) }
      let accepted = try await provider.updateMutableWorkflow(
        input: GraphQLUpdateMutableWorkflowInput(
          target: target,
          definition: definition,
          expectedDefinitionRevision: entry.definitionRevision
        ),
        resolvedBundleURL: acceptedRoot
      )
      let acceptedEntry = try await detail(provider: provider, mutation: accepted)
      XCTAssertNotEqual(acceptedEntry.definitionRevision, entry.definitionRevision)
      let acceptedDefinition = try XCTUnwrap(acceptedEntry.definition)
      try await assertRejectedUpdate(
        provider: provider,
        target: target,
        revision: acceptedEntry.definitionRevision,
        definition: acceptedDefinition.merging(["metadata": retained]) { _, new in new },
        expectedCode: .invalidWorkflow
      )

      let replacementDefinition = acceptedDefinition.merging([
        "metadata": .object(["customValue": .string("REPLACEMENT_SECRET_CANARY")])
      ]) { _, new in new }
      let replacementRoot = try definitionBundle(replacementDefinition)
      defer { try? FileManager.default.removeItem(at: replacementRoot) }
      let replacement = try await provider.updateMutableWorkflow(
        input: GraphQLUpdateMutableWorkflowInput(
          target: target,
          definition: replacementDefinition,
          expectedDefinitionRevision: acceptedEntry.definitionRevision
        ),
        resolvedBundleURL: replacementRoot
      )
      let replacementEntry = try await detail(provider: provider, mutation: replacement)
      let replacementProjection = try XCTUnwrap(replacementEntry.definition)
      let replacementText = try XCTUnwrap(String(
        data: try JSONEncoder().encode(JSONValue.object(replacementProjection)),
        encoding: .utf8
      ))
      XCTAssertFalse(replacementText.contains("REPLACEMENT_SECRET_CANARY"))
      let persistedText = try XCTUnwrap(String(data: Data(contentsOf: persistedURL), encoding: .utf8))
      XCTAssertTrue(persistedText.contains("REPLACEMENT_SECRET_CANARY"))
    }
  }

  func testProjectionLimitFailsBeforeRegistrationAndUpdatePublication() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": home.path]) {
      let provider = webProvider()
      let oversized = try makeBundle(
        description: "Oversized projection",
        includeNode: true,
        workflowId: "projection-limit"
      )
      defer { try? FileManager.default.removeItem(at: oversized) }
      var oversizedDefinition = try definition(at: oversized)
      for index in 0..<10_000 {
        oversizedDefinition["extension\(index)"] = .string("x")
      }
      try writeDefinition(oversizedDefinition, to: oversized)
      XCTAssertLessThan(
        try Data(contentsOf: oversized.appendingPathComponent("workflow.json")).count,
        WorkflowWebProjectionPolicy.definitionResponseLimit
      )

      await assertRegistryError(.invalidWorkflow) {
        _ = try await provider.registerMutableWorkflow(
          input: GraphQLRegisterMutableWorkflowInput(definition: oversizedDefinition),
          resolvedBundleURL: oversized
        )
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(
        ".riela/temporary-workflows/projection-limit"
      ).path))

      let initial = try makeBundle(description: "Initial", includeNode: true)
      defer { try? FileManager.default.removeItem(at: initial) }
      let registered = try await provider.registerMutableWorkflow(
        input: GraphQLRegisterMutableWorkflowInput(definition: [:]),
        resolvedBundleURL: initial
      )
      let entry = try await detail(provider: provider, mutation: registered)
      let persistedURL = home.appendingPathComponent(
        ".riela/temporary-workflows/web-registry-test/workflow.json"
      )
      let originalData = try Data(contentsOf: persistedURL)
      var updateDefinition = try XCTUnwrap(entry.definition)
      for index in 0..<10_000 {
        updateDefinition["extension\(index)"] = .string("x")
      }
      let updateRoot = try definitionBundle(updateDefinition)
      defer { try? FileManager.default.removeItem(at: updateRoot) }

      await assertRegistryError(.invalidWorkflow) {
        _ = try await provider.updateMutableWorkflow(
          input: GraphQLUpdateMutableWorkflowInput(
            target: self.exactTarget(entry),
            definition: updateDefinition,
            expectedDefinitionRevision: entry.definitionRevision
          ),
          resolvedBundleURL: updateRoot
        )
      }
      XCTAssertEqual(try Data(contentsOf: persistedURL), originalData)
    }
  }

  func testDefinitionProjectionUsesSchemaPathsForStructuralNames() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": home.path]) {
      let provider = webProvider()
      let bundle = try makeBundle(description: "Path-aware", includeNode: true)
      defer { try? FileManager.default.removeItem(at: bundle) }
      var authored = try definition(at: bundle)
      authored["model"] = .string("pin-1234")
      if case var .object(defaults)? = authored["defaults"] {
        defaults["enabled"] = .string("door-code")
        authored["defaults"] = .object(defaults)
      }
      try writeDefinition(authored, to: bundle)

      let registered = try await provider.registerMutableWorkflow(
        input: GraphQLRegisterMutableWorkflowInput(definition: authored),
        resolvedBundleURL: bundle
      )
      let entry = try await detail(provider: provider, mutation: registered)
      let projected = try XCTUnwrap(entry.definition)
      let projectedText = try XCTUnwrap(String(
        data: try JSONEncoder().encode(JSONValue.object(projected)),
        encoding: .utf8
      ))
      XCTAssertFalse(projectedText.contains("pin-1234"))
      XCTAssertFalse(projectedText.contains("door-code"))
      XCTAssertEqual(projected["workflowId"], .string("web-registry-test"))
      assertRetainPlaceholder(projected["model"])
      if case let .object(defaults)? = projected["defaults"] {
        assertRetainPlaceholder(defaults["enabled"])
      } else {
        XCTFail("Expected projected defaults")
      }
    }
  }

  func testWebProviderRejectsNonUserAndInexactTargets() async throws {
    let provider = webProvider()
    await assertRegistryError(.invalidFilter) {
      _ = try await provider.workflows(filter: WorkflowRegistryFilter(scope: .project))
    }
    await assertRegistryError(.invalidOrigin) {
      _ = try await provider.workflow(target: WorkflowRegistryTarget(
        workflowId: "web-registry-test",
        scope: .user
      ))
    }
    await assertRegistryError(.invalidOrigin) {
      _ = try await provider.workflow(target: WorkflowRegistryTarget(
        workflowId: "web-registry-test",
        scope: .project,
        originId: "project:web-registry-test"
      ))
    }
  }

  func testWebProviderRejectsExactImmutableUserOrigin() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": home.path]) {
      let source = try makeBundle(
        description: "Immutable",
        includeNode: true,
        workflowId: "immutable-web-query"
      )
      defer { try? FileManager.default.removeItem(at: source) }
      let destination = home.appendingPathComponent(
        ".riela/workflows/immutable-web-query",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.copyItem(at: source, to: destination)
      let entry = try XCTUnwrap(WorkflowRegistryService().list(
        filter: WorkflowRegistryFilter(scope: .user),
        workingDirectory: home.path
      ).first { $0.workflowId == "immutable-web-query" })
      XCTAssertEqual(entry.provenance, .immutable)

      await assertRegistryError(.immutableWorkflow) {
        _ = try await self.webProvider(workingDirectory: home.path).workflow(
          target: WorkflowRegistryTarget(
            workflowId: entry.workflowId,
            scope: .user,
            originId: entry.originId
          )
        )
      }
    }
  }

  func testWebProviderRejectsOverDepthRegistrationAndUpdateWithoutMutation() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": home.path]) {
      let provider = webProvider()
      let initial = try makeBundle(description: "Initial", includeNode: true)
      defer { try? FileManager.default.removeItem(at: initial) }
      let registered = try await provider.registerMutableWorkflow(
        input: GraphQLRegisterMutableWorkflowInput(definition: [:]),
        resolvedBundleURL: initial
      )
      let entry = try await detail(provider: provider, mutation: registered)
      let persistedURL = home.appendingPathComponent(
        ".riela/temporary-workflows/web-registry-test/workflow.json"
      )
      let originalData = try Data(contentsOf: persistedURL)
      guard case var .object(definition) = try JSONDecoder().decode(
        JSONValue.self,
        from: originalData
      ) else {
        return XCTFail("Expected an object definition")
      }
      definition["metadata"] = overDepthValue()
      let overDepthRoot = try definitionBundle(definition)
      defer { try? FileManager.default.removeItem(at: overDepthRoot) }

      await assertRegistryError(.invalidWorkflow) {
        _ = try await provider.registerMutableWorkflow(
          input: GraphQLRegisterMutableWorkflowInput(definition: definition),
          resolvedBundleURL: overDepthRoot
        )
      }
      await assertRegistryError(.invalidWorkflow) {
        _ = try await provider.updateMutableWorkflow(
          input: GraphQLUpdateMutableWorkflowInput(
            target: self.exactTarget(entry),
            definition: definition,
            expectedDefinitionRevision: entry.definitionRevision
          ),
          resolvedBundleURL: overDepthRoot
        )
      }
      XCTAssertEqual(try Data(contentsOf: persistedURL), originalData)
    }
  }

  func testStaleDeleteAndActivationFailWithoutMutation() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": home.path]) {
      let provider = webProvider()
      let bundle = try makeBundle(description: "Initial", includeNode: true)
      defer { try? FileManager.default.removeItem(at: bundle) }
      let registered = try await provider.registerMutableWorkflow(
        input: GraphQLRegisterMutableWorkflowInput(definition: [:], activationState: .active),
        resolvedBundleURL: bundle
      )
      let entry = try await detail(provider: provider, mutation: registered)

      await assertRegistryError(.registryConflict) {
        _ = try await provider.deleteMutableWorkflow(input: GraphQLDeleteMutableWorkflowInput(
          target: exactTarget(entry),
          expectedDefinitionRevision: "stale"
        ))
      }
      await assertRegistryError(.registryConflict) {
        _ = try await provider.setWorkflowActivation(
          input: GraphQLSetWorkflowActivationInput(
            target: exactTarget(entry),
            expectedDefinitionRevision: entry.definitionRevision,
            expectedActivationState: .deactivated
          ),
          state: .deactivated
        )
      }

      let current = try await provider.workflow(target: WorkflowRegistryTarget(
        workflowId: entry.workflowId,
        scope: .user,
        originId: entry.originId
      ))
      XCTAssertEqual(current.activationState, "ACTIVE")
      XCTAssertEqual(current.definitionRevision, entry.definitionRevision)
      XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(
        ".riela/temporary-workflows/web-registry-test/workflow.json"
      ).path))
    }
  }

  func testRegistryRootIgnoresWorkingDirectoryAndCrossOriginRetainReplay() async throws {
    let home = try makeHome()
    let unrelated = try makeHome()
    defer {
      try? FileManager.default.removeItem(at: home)
      try? FileManager.default.removeItem(at: unrelated)
    }
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": home.path]) {
      let key = Data(repeating: 0x7b, count: 32)
      let provider = webProvider(
        principalId: "principal-a",
        retainKey: key,
        workingDirectory: unrelated.path
      )
      let firstBundle = try makeBundle(
        description: "First",
        includeNode: true,
        includeSecretMetadata: true,
        workflowId: "web-registry-first"
      )
      let secondBundle = try makeBundle(
        description: "Second",
        includeNode: true,
        includeSecretMetadata: true,
        workflowId: "web-registry-second"
      )
      defer {
        try? FileManager.default.removeItem(at: firstBundle)
        try? FileManager.default.removeItem(at: secondBundle)
      }
      let firstResult = try await provider.registerMutableWorkflow(
        input: GraphQLRegisterMutableWorkflowInput(definition: [:]),
        resolvedBundleURL: firstBundle
      )
      let first = try await detail(provider: provider, mutation: firstResult)
      let secondResult = try await provider.registerMutableWorkflow(
        input: GraphQLRegisterMutableWorkflowInput(definition: [:]),
        resolvedBundleURL: secondBundle
      )
      let second = try await detail(provider: provider, mutation: secondResult)
      let firstRetain = try XCTUnwrap(first.definition?["metadata"])
      let secondDefinition = try XCTUnwrap(second.definition)
      let submitted = secondDefinition.merging(["metadata": firstRetain]) { _, new in new }

      try await assertRejectedUpdate(
        provider: provider,
        target: exactTarget(second),
        revision: second.definitionRevision,
        definition: submitted,
        expectedCode: .invalidWorkflow
      )
      XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(
        ".riela/temporary-workflows/web-registry-first/workflow.json"
      ).path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: unrelated.appendingPathComponent(
        ".riela/temporary-workflows/web-registry-first/workflow.json"
      ).path))
    }
  }

  func testConcurrentWebUpdatesShareCanonicalRegistryLocks() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": home.path]) {
      let provider = webProvider()
      let initial = try makeBundle(description: "Initial", includeNode: true)
      defer { try? FileManager.default.removeItem(at: initial) }
      let registered = try await provider.registerMutableWorkflow(
        input: GraphQLRegisterMutableWorkflowInput(definition: [:]),
        resolvedBundleURL: initial
      )
      let entry = try await detail(provider: provider, mutation: registered)
      let first = try makeBundle(description: "First", includeNode: false)
      let second = try makeBundle(description: "Second", includeNode: false)
      defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
      }
      let target = exactTarget(entry)

      let accepted = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        for bundle in [first, second] {
          group.addTask {
            do {
              _ = try await provider.updateMutableWorkflow(
                input: GraphQLUpdateMutableWorkflowInput(
                  target: target,
                  definition: [:],
                  expectedDefinitionRevision: entry.definitionRevision
                ),
                resolvedBundleURL: bundle
              )
              return true
            } catch {
              return false
            }
          }
        }
        var results: [Bool] = []
        for await result in group { results.append(result) }
        return results
      }
      XCTAssertEqual(accepted.filter { $0 }.count, 1)
    }
  }

  private func assertRejectedUpdate(
    provider: FileWorkflowRegistryGraphQLProvider,
    target: GraphQLWorkflowTargetInput,
    revision: String?,
    definition: JSONObject,
    expectedCode: WorkflowRegistryErrorCode
  ) async throws {
    let root = try definitionBundle(definition)
    defer { try? FileManager.default.removeItem(at: root) }
    await assertRegistryError(expectedCode) {
      _ = try await provider.updateMutableWorkflow(
        input: GraphQLUpdateMutableWorkflowInput(
          target: target,
          definition: definition,
          expectedDefinitionRevision: revision
        ),
        resolvedBundleURL: root
      )
    }
  }

  private func detail(
    provider: FileWorkflowRegistryGraphQLProvider,
    mutation: GraphQLWorkflowMutationPayload
  ) async throws -> GraphQLWorkflowRegistryEntry {
    let summary = try XCTUnwrap(mutation.workflow)
    return try await provider.workflow(target: WorkflowRegistryTarget(
      workflowId: summary.workflowId,
      scope: .user,
      originId: summary.originId
    ))
  }

  private func definition(at root: URL) throws -> JSONObject {
    guard case let .object(definition) = try JSONDecoder().decode(
      JSONValue.self,
      from: Data(contentsOf: root.appendingPathComponent("workflow.json"))
    ) else {
      throw WorkflowRegistryError(
        code: .invalidWorkflow,
        message: "test definition must be an object"
      )
    }
    return definition
  }

  private func writeDefinition(_ definition: JSONObject, to root: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(JSONValue.object(definition))
      .write(to: root.appendingPathComponent("workflow.json"), options: .atomic)
  }

  private func assertRetainPlaceholder(
    _ value: JSONValue?,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case let .object(object)? = value,
          object.count == 1,
          case .string? = object["$rielaRetain"] else {
      return XCTFail("Expected opaque retain placeholder", file: file, line: line)
    }
  }

  private func webProvider(
    principalId: String = "riela-app-local-web",
    retainKey: Data = Data(repeating: 0x2a, count: 32),
    workingDirectory: String = FileManager.default.currentDirectoryPath
  ) -> FileWorkflowRegistryGraphQLProvider {
    FileWorkflowRegistryGraphQLProvider(
      workingDirectory: workingDirectory,
      webPrincipalId: principalId,
      retainKey: retainKey
    )
  }

  private func exactTarget(_ entry: GraphQLWorkflowRegistryEntry) -> GraphQLWorkflowTargetInput {
    GraphQLWorkflowTargetInput(
      workflowId: entry.workflowId,
      scope: .user,
      originId: entry.originId
    )
  }

  private func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-web-registry-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
  }

  private func makeBundle(
    description: String,
    includeNode: Bool,
    includeSecretMetadata: Bool = false,
    workflowId: String = "web-registry-test"
  ) throws -> URL {
    let definition: JSONObject = [
      "workflowId": .string(workflowId),
      "description": .string(description),
      "defaults": .object(["nodeTimeoutMs": .number(120_000), "maxLoopIterations": .number(3)]),
      "entryStepId": .string("main"),
      "nodes": .array([.object(["id": .string("main"), "nodeFile": .string("nodes/main.json")])]),
      "steps": .array([.object([
        "id": .string("main"),
        "nodeId": .string("main"),
        "role": .string("worker")
      ])])
    ].merging(includeSecretMetadata ? [
      "metadata": .object(["customValue": .string("SECRET_CANARY_VALUE")])
    ] : [:]) { _, new in new }
    let root = try definitionBundle(definition)
    if includeNode {
      let nodes = root.appendingPathComponent("nodes", isDirectory: true)
      let prompts = root.appendingPathComponent("prompts", isDirectory: true)
      try FileManager.default.createDirectory(at: nodes, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: prompts, withIntermediateDirectories: true)
      try Data("""
        {
          "id": "main",
          "executionBackend": "codex-agent",
          "model": "gpt-5.3-codex-spark",
          "promptTemplateFile": "prompts/main.md",
          "variables": {}
        }
        """.utf8)
        .write(to: nodes.appendingPathComponent("main.json"))
      try Data("Complete the task.".utf8).write(to: prompts.appendingPathComponent("main.md"))
    }
    return root
  }

  private func definitionBundle(_ definition: JSONObject) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-web-registry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(JSONValue.object(definition))
      .write(to: root.appendingPathComponent("workflow.json"))
    return root
  }

  private func overDepthValue() -> JSONValue {
    (0...WorkflowRegistryDefinitionInputPolicy.maximumDepth).reduce(.string("value")) { value, index in
      .object(["level\(index)": value])
    }
  }
}

private func assertRegistryError(
  _ expectedCode: WorkflowRegistryErrorCode,
  _ expression: () async throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await expression()
    XCTFail("Expected expression to throw", file: file, line: line)
  } catch let error as WorkflowRegistryError {
    XCTAssertEqual(error.code, expectedCode, file: file, line: line)
  } catch {
    XCTFail("Expected WorkflowRegistryError, got \(error)", file: file, line: line)
  }
}
#endif
