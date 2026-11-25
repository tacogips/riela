import Foundation
import XCTest
@testable import RielaCore

final class ModelCatalogTests: XCTestCase {
  func testEveryBuiltInStartsWithDefault() {
    let instances = NodeExecutionBackend.allCases.map(ProviderInstance.builtIn)
    let catalog = ModelCatalog.build(instances: instances, reports: [:])
    XCTAssertEqual(catalog.map(\.instance), instances)
    for entry in catalog {
      XCTAssertEqual(entry.models.first?.id, ModelSentinel.defaultModel)
      XCTAssertEqual(entry.models.first?.sources, ["manifest"])
      XCTAssertEqual(entry.models.first?.options, CatalogModelOptions())
      XCTAssertGreaterThan(entry.models.count, 1)
      XCTAssertNil(entry.report)
    }
  }

  func testReportedOptionsWinAndCustomOptionsFillRemainingLists() throws {
    let manifest = try XCTUnwrap(ModelManifest.models[.codexAgent]?.first)
    XCTAssertEqual(manifest.options.reasoningEfforts, NodeReasoningEffort.allCases.map(\.rawValue))
    let instance = ProviderInstance(instanceId: "team/codex", driver: .codexAgent, customModels: [
      ManifestModel(id: manifest.id, label: "Custom label", options: .init(reasoningEfforts: ["high"], serviceTiers: ["fast"], modes: ["edit"])),
      ManifestModel(id: "team-model")
    ])
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let report = ProviderReport(instanceId: instance.instanceId, observedAt: date, reportedModels: [
      ManifestModel(id: manifest.id, label: "Reported label", options: .init(reasoningEfforts: ["medium"], modes: ["plan"])),
      ManifestModel(id: "reported-only")
    ])
    let catalog = ModelCatalog.build(
      instances: [.builtIn(.codexAgent), instance], reports: [instance.instanceId: report]
    )
    let matching = catalog[1].models.filter { $0.id == manifest.id }
    XCTAssertEqual(matching.count, 1)
    let merged = try XCTUnwrap(matching.first)
    XCTAssertEqual(merged.sources, ["custom", "manifest", "reported"])
    XCTAssertEqual(merged.observedAt, date)
    XCTAssertEqual(merged.label, "Reported label")
    XCTAssertEqual(merged.options, .init(reasoningEfforts: ["medium"], serviceTiers: ["fast"], modes: ["plan"]))
    XCTAssertEqual(catalog[1].models.suffix(2).map(\.id), ["reported-only", "team-model"])
    XCTAssertFalse(catalog[0].models.contains { $0.id == "team-model" || $0.id == "reported-only" })

    let builtIn = ProviderInstance.builtIn(.codexAgent)
    let builtInReport = ProviderReport(
      instanceId: builtIn.instanceId, observedAt: date, reportedModels: report.reportedModels
    )
    let withoutCustom = ModelCatalog.build(instances: [builtIn], reports: [builtIn.instanceId: builtInReport])
    let reported = try XCTUnwrap(withoutCustom[0].models.first { $0.id == manifest.id })
    XCTAssertEqual(reported.sources, ["manifest", "reported"])
    XCTAssertEqual(reported.options.reasoningEfforts, ["medium"])
    XCTAssertEqual(reported.options.serviceTiers, [])
  }

  func testKnownModelsAndWarningAreDriverScoped() {
    let instance = ProviderInstance(instanceId: "team", driver: .codexAgent, customModels: [ManifestModel(id: "team-model")])
    let catalog = ModelCatalog.build(instances: [instance], reports: [:])
    for model in [nil, "", ModelSentinel.defaultModel, "team-model"] {
      XCTAssertTrue(ModelCatalog.isKnown(model: model, driver: .codexAgent, catalog: catalog))
    }
    XCTAssertFalse(ModelCatalog.isKnown(model: "missing", driver: .codexAgent, catalog: catalog))
    let diagnostics = ModelCatalog.diagnostics(nodeModels: [
      .init(path: "node.a", driver: .codexAgent, model: "team-model"),
      .init(path: "node.b", driver: .claudeCodeAgent, model: "team-model"),
      .init(path: "node.c", driver: .codexAgent, model: nil)
    ], catalog: catalog)
    XCTAssertEqual(diagnostics, [
      .init(severity: .warning, path: "node.b", message: "model_unknown: 'team-model' is not in the catalog for claude-code-agent")
    ])
  }

  func testReservedSentinelCannotAcquireModelMetadata() {
    let sentinel = ManifestModel(id: ModelSentinel.defaultModel, label: "Other", options: .init(modes: ["plan"]))
    let instance = ProviderInstance(instanceId: "team", driver: .codexAgent, customModels: [sentinel])
    let report = ProviderReport(instanceId: instance.instanceId, observedAt: Date(timeIntervalSince1970: 0), reportedModels: [sentinel])
    let models = ModelCatalog.build(instances: [instance], reports: [instance.instanceId: report])[0].models
    let defaults = models.filter { $0.id == ModelSentinel.defaultModel }
    XCTAssertEqual(defaults.count, 1)
    XCTAssertEqual(defaults.first?.sources, ["manifest"])
    XCTAssertEqual(defaults.first?.options, CatalogModelOptions())
    XCTAssertNil(defaults.first?.label)
    XCTAssertNil(defaults.first?.observedAt)
  }
}
