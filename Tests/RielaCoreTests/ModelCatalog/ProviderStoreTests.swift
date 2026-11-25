import Foundation
import XCTest
@testable import RielaCore

final class ProviderStoreTests: XCTestCase {
  private let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

  func testReadsDoNotCreateStoreAndUsersFollowBuiltInsInIDOrder() throws {
    try withStore { store in
      let builtIns = NodeExecutionBackend.allCases.map(ProviderInstance.builtIn)
      XCTAssertEqual(try store.providerInstances(), builtIns)
      XCTAssertEqual(try store.providerInstance(id: "official/openai-sdk"), .builtIn(.officialOpenAISDK))
      XCTAssertNil(try store.providerInstance(id: "unknown"))
      XCTAssertNil(try store.providerReport(instanceId: "official/openai-sdk"))
      XCTAssertEqual(try store.providerReports(), [:])
      XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionStoreRoot))

      let team = ProviderInstance(
        instanceId: "team/openai", driver: .officialOpenAISDK, label: "Team", account: "Shared",
        providerName: "named", providerProxy: "proxy", apiKeyEnvironment: "TEAM_OPENAI_KEY",
        customModels: [ManifestModel(id: "team-model")]
      )
      let another = ProviderInstance(instanceId: "another", driver: .officialOpenAISDK)
      try store.saveProviderInstance(team)
      try store.saveProviderInstance(another)
      XCTAssertEqual(try store.providerInstances(), builtIns + [another, team])
      XCTAssertEqual(try store.providerInstance(id: team.instanceId), team)
    }
  }

  func testRejectsReservedAndInvalidInstancesWithoutWriting() throws {
    try withStore { store in
      let reserved = ProviderInstance(instanceId: "official/openai-sdk", driver: .codexAgent)
      assertError("provider_instance_reserved", try store.saveProviderInstance(reserved))
      assertError("provider_instance_reserved", try store.removeProviderInstance(id: reserved.instanceId))
      assertError("provider_instance_reserved", try store.saveProviderInstance(.builtIn(.codexAgent)))
      let invalid = [
        ProviderInstance(instanceId: "team\n", driver: .codexAgent),
        ProviderInstance(instanceId: "team", driver: .codexAgent, apiKeyEnvironment: "sk-abc"),
        ProviderInstance(instanceId: "team", driver: .codexAgent, apiKeyEnvironment: "KEY\n"),
        ProviderInstance(instanceId: "team", driver: .codexAgent, customModels: [ManifestModel(id: ModelSentinel.defaultModel)])
      ]
      for instance in invalid {
        assertError("provider_instance_invalid", try store.saveProviderInstance(instance))
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionStoreRoot))
    }
  }

  func testPartialReportsAndProbePreserveEachOthersFields() throws {
    try withStore { store in
      let id = NodeExecutionBackend.codexAgent.rawValue
      try store.mergeReportedConfig(instanceId: id, configOptions: [
        option("model", "model", ["listed", "listed", ModelSentinel.defaultModel], current: "current"),
        option("mode", "mode", ["edit", "plan"]),
        option("thought", "thought_level", ["high"]),
        option("service-tier", "model_config", ["fast"]),
        option("verbosity", "model_config", ["low"]),
        ["category": .string("model"), "values": .array([.string("ignore")])],
        ["id": .string("invalid-mode"), "category": .string("mode"), "values": .array([.bool(true)])],
        option("other", "future", ["ignore"])
      ], at: observedAt)
      let configured = try XCTUnwrap(store.providerReport(instanceId: id))
      XCTAssertEqual(configured.currentModel, "current")
      XCTAssertEqual(configured.reportedModels.map(\.id), ["listed", "current"])
      let options = CatalogModelOptions(reasoningEfforts: ["high"], serviceTiers: ["fast"], modes: ["edit", "plan"])
      XCTAssertEqual(configured.reportedModels.map(\.options), [options, options])
      XCTAssertNil(configured.availability)
      XCTAssertNil(configured.authentication)
      XCTAssertNil(configured.version)
      XCTAssertNil(configured.failures)
      XCTAssertNil(configured.probedAt)

      let probeDate = observedAt.addingTimeInterval(10)
      let capability = BackendCapability(
        backend: .codexAgent, source: .observed, availability: .available, authentication: .failed,
        version: "1.2", models: ["probe-model"], failures: ["Credential missing"]
      )
      try store.recordProbe(instanceId: id, capability: capability, at: probeDate)
      let probed = try XCTUnwrap(store.providerReport(instanceId: id))
      XCTAssertEqual(probed.reportedModels, configured.reportedModels)
      XCTAssertEqual(probed.observedAt, observedAt)

      let later = probeDate.addingTimeInterval(10)
      try store.mergeReportedConfig(instanceId: id, reportedModel: "turn-model", at: later)
      let updated = try XCTUnwrap(store.providerReport(instanceId: id))
      XCTAssertEqual(updated.reportedModels.map(\.id), ["listed", "current", "turn-model"])
      XCTAssertEqual(updated.reportedModels.map(\.options), [options, options, options])
      XCTAssertEqual(updated.currentModel, "turn-model")
      XCTAssertEqual(updated.observedAt, later)
      XCTAssertEqual(updated.availability, .available)
      XCTAssertEqual(updated.authentication, .failed)
      XCTAssertEqual(updated.version, "1.2")
      XCTAssertEqual(updated.failures, ["Credential missing"])
      XCTAssertEqual(updated.probedAt, probeDate)
      XCTAssertEqual(try store.providerReports(), [id: updated])
    }
  }

  func testRemoveClearsOnlyItsReportAndMissingInstanceCannotRecreateIt() throws {
    try withStore { store in
      let id = "team"
      let builtIn = NodeExecutionBackend.codexAgent.rawValue
      try store.saveProviderInstance(ProviderInstance(instanceId: id, driver: .codexAgent))
      try store.mergeReportedConfig(instanceId: id, reportedModel: "user-model", at: observedAt)
      try store.mergeReportedConfig(instanceId: builtIn, reportedModel: "built-in-model", at: observedAt)
      try store.removeProviderInstance(id: id)
      XCTAssertNil(try store.providerInstance(id: id))
      XCTAssertNil(try store.providerReport(instanceId: id))
      XCTAssertEqual(try store.providerReport(instanceId: builtIn)?.currentModel, "built-in-model")
      assertError("provider_instance_not_found", try store.removeProviderInstance(id: id))
      assertError("provider_instance_not_found", try store.mergeReportedConfig(instanceId: id, reportedModel: "late", at: observedAt))
      XCTAssertNil(try store.providerReport(instanceId: id))
    }
  }

  func testOptionsReportedBeforeAnyModelsReachTheFirstReportedModel() throws {
    try withStore { store in
      let id = NodeExecutionBackend.codexAgent.rawValue
      try store.mergeReportedConfig(
        instanceId: id, configOptions: [option("mode", "mode", ["plan"])], at: observedAt
      )
      XCTAssertEqual(try store.providerReport(instanceId: id)?.reportedModels, [])
      try store.mergeReportedConfig(
        instanceId: id, reportedModel: "turn-model", at: observedAt.addingTimeInterval(1)
      )
      XCTAssertEqual(try store.providerReport(instanceId: id)?.reportedModels, [
        ManifestModel(id: "turn-model", options: CatalogModelOptions(modes: ["plan"]))
      ])
    }
  }

  func testChangingDriverClearsOldDriverReport() throws {
    try withStore { store in
      let id = "team"
      try store.saveProviderInstance(ProviderInstance(instanceId: id, driver: .codexAgent))
      try store.mergeReportedConfig(instanceId: id, reportedModel: "codex-model", at: observedAt)
      let changed = ProviderInstance(instanceId: id, driver: .claudeCodeAgent)
      try store.saveProviderInstance(changed)
      XCTAssertEqual(try store.providerInstance(id: id), changed)
      XCTAssertNil(try store.providerReport(instanceId: id))
    }
  }

  private func withStore(_ body: (BotStore) throws -> Void) rethrows {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(BotStore(sessionStoreRoot: root.path))
  }

  private func option(_ id: String, _ category: String, _ values: [String], current: String? = nil) -> JSONObject {
    var option: JSONObject = ["id": .string(id), "category": .string(category), "values": .array(values.map(JSONValue.string))]
    if let current { option["currentValue"] = .string(current) }
    return option
  }

  private func assertError<Result>(
    _ code: String, _ run: @autoclosure () throws -> Result, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(try run(), file: file, line: line) { error in
      XCTAssertEqual((error as? BotStoreError)?.code, code, file: file, line: line)
    }
  }
}
