import Foundation
import RielaCore
import RielaGraphQL
import XCTest
@testable import RielaCLI

final class ModelCatalogCommandTests: XCTestCase {
  func testModelListHasBuiltInsAndCustomModels() async throws {
    let fixture = try fixture()
    let empty: ModelCatalogPayload = try await fixture.json(["model", "list"])
    XCTAssertEqual(Set(empty.providers.map(\.driver)), Set(NodeExecutionBackend.allCases))
    XCTAssertTrue(empty.providers.allSatisfy { $0.models.first?.id == ModelSentinel.defaultModel })
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.databasePath))

    let created: ProviderPayload = try await fixture.json([
      "provider", "add", "--id", "work/codex", "--driver", "codex-agent", "--custom-model", "x1", "--custom-model", "x2"
    ])
    XCTAssertEqual(created.provider.instanceId, "work/codex")
    let custom: ModelCatalogPayload = try await fixture.json(["model", "list", "--provider", "work/codex"])
    XCTAssertEqual(custom.providers.map(\.instanceId), ["work/codex"])
    XCTAssertEqual(custom.providers.first?.models.filter { $0.sources == ["custom"] }.map(\.id), ["x1", "x2"])

    let updated: ProviderPayload = try await fixture.json([
      "provider", "update", "work/codex", "--account", "Work", "--custom-model", "replacement"
    ])
    XCTAssertEqual(updated.provider.account, "Work")
    XCTAssertEqual(updated.provider.models.filter { $0.sources == ["custom"] }.map(\.id), ["replacement"])
    let cleared: ProviderPayload = try await fixture.json(["provider", "update", "work/codex", "--clear-custom-models"])
    XCTAssertFalse(cleared.provider.models.contains { $0.sources.contains("custom") })
    let removed: ProviderListPayload = try await fixture.json(["provider", "remove", "work/codex"])
    XCTAssertFalse(removed.providers.contains { $0.instanceId == "work/codex" })
  }

  func testAssistantCatalogUsesBuiltInReportsInManifestOrder() throws {
    let fixture = try fixture()
    let driver = NodeExecutionBackend.codexAgent
    let team = ProviderInstance(instanceId: "team/codex", driver: driver, customModels: [.init(id: "private-model")])
    try fixture.store.saveProviderInstance(team)
    try fixture.store.mergeReportedConfig(
      instanceId: driver.rawValue, reportedModel: "reported-model", at: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let models = try XCTUnwrap(AssistantCatalogModels.builtIn(sessionStoreRoot: fixture.sessions, environment: [:]))
    XCTAssertEqual(models[driver], ModelManifest.models[driver, default: []].map(\.id) + ["reported-model"])
  }

  func testBuiltInInstancesCannotBeModified() async throws {
    let fixture = try fixture()
    for command in [
      ["provider", "add", "--id", "codex-agent", "--driver", "codex-agent"],
      ["provider", "remove", "codex-agent"]
    ] {
      let result = await fixture.run(command)
      XCTAssertEqual(result.exitCode, .failure)
      XCTAssertTrue(result.stderr.contains("provider_instance_reserved"), result.stderr)
    }
  }

  func testRefreshPersistsProbeAndReadsNeverProbe() async throws {
    let fixture = try fixture()
    let counter = CatalogProbeCounter()
    let at = Date(timeIntervalSince1970: 1_700_000_000)
    let service = ModelCatalogService(
      store: fixture.store, environment: [:], now: { at }, probe: { instance, _, date in
        await counter.observe(instance.driver, at: date)
      }
    )
    let runner = ModelCatalogCommands(serviceOverride: service)
    let refreshed = await runner.run(
      kind: .provider, options: .init(scope: "provider", command: "refresh", target: "codex-agent", output: .json)
    )
    XCTAssertEqual(refreshed.exitCode, .success, refreshed.stderr)
    XCTAssertEqual(try fixture.store.providerReport(instanceId: "codex-agent")?.probedAt, at)
    let shown = await runner.run(
      kind: .provider, options: .init(scope: "provider", command: "show", target: "codex-agent", output: .text)
    )
    XCTAssertTrue(shown.stdout.contains("available"))
    XCTAssertTrue(shown.stdout.contains(RoutineStore.timestamp(at) + " (0s ago)"))
    let listed = await runner.run(kind: .provider, options: .init(scope: "provider", command: "list", output: .json))
    XCTAssertEqual(listed.exitCode, .success)
    let catalog = await runner.run(kind: .model, options: .init(scope: "model", command: "list", output: .json))
    XCTAssertEqual(catalog.exitCode, .success)
    let drivers = await counter.drivers
    XCTAssertEqual(drivers, [.codexAgent])
  }

  func testBotCreateAndUpdateWarningsAndProviderValidation() async throws {
    let fixture = try fixture()
    let unknown = await fixture.run(["bot", "create", "--name", "Warn", "--backend", "codex-agent", "--model", "nope"])
    XCTAssertEqual(unknown.exitCode, .success)
    XCTAssertTrue(unknown.stderr.contains("model_unknown"))
    XCTAssertEqual(try fixture.store.load(botId: "warn")?.defaultModel, "nope")

    let updated: BotMutationPayload = try await fixture.json(["bot", "update", "warn", "--model", "nope-again"])
    XCTAssertEqual(updated.warnings.count, 1)
    XCTAssertTrue(updated.warnings.first?.contains("model_unknown") == true)
    let known = await fixture.run(["bot", "create", "--name", "Default", "--backend", "codex-agent", "--model", "default"])
    XCTAssertEqual(known.exitCode, .success)
    XCTAssertTrue(known.stderr.isEmpty, known.stderr)
    let missing = await fixture.run(["bot", "create", "--name", "Invalid", "--provider", "missing"])
    XCTAssertTrue(missing.stderr.contains("provider_instance_not_found"), missing.stderr)
    XCTAssertNil(try fixture.store.load(botId: "invalid"))
    let rejected = await fixture.run(["bot", "update", "warn", "--provider", "missing"])
    XCTAssertTrue(rejected.stderr.contains("provider_instance_not_found"), rejected.stderr)
    XCTAssertNil(try fixture.store.load(botId: "warn")?.providerInstanceId)
  }

  private func fixture() throws -> CatalogCommandFixture {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/bots-overview/bots-13-model-surfaces/test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return CatalogCommandFixture(root: root)
  }
}

private struct CatalogCommandFixture {
  let root: URL
  var sessions: String { root.appendingPathComponent(".riela/sessions").path }
  var store: BotStore { BotStore(sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: sessions)) }

  func run(_ command: [String]) async -> CLICommandResult {
    let environment = [
      "HOME": root.path, "RIELA_WORKFLOW_HOME": root.appendingPathComponent("user").path,
      "XDG_STATE_HOME": root.appendingPathComponent("state").path
    ]
    return await RielaCLIApplication().run(
      command + ["--working-dir", root.path, "--session-store", sessions], environment: environment
    )
  }

  func json<Value: Decodable>(_ command: [String]) async throws -> Value {
    let result = await run(command + ["--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Value.self, from: Data(result.stdout.utf8))
  }
}

private actor CatalogProbeCounter {
  private(set) var drivers: [NodeExecutionBackend] = []

  func observe(_ driver: NodeExecutionBackend, at date: Date) -> BackendCapability {
    drivers.append(driver)
    return BackendCapability(
      backend: driver, source: .observed, observedAt: date, availability: .available, authentication: .available, version: "1"
    )
  }
}
