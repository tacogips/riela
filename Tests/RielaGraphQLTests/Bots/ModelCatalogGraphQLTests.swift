import Foundation
import RielaCore
import RielaGraphQL
import XCTest

final class ModelCatalogGraphQLTests: XCTestCase {
  func testReadFieldsReachProviderAndProjectModels() async {
    let provider = RecordingBotsProvider()
    let result = await execute("""
      {
        modelCatalog(providerInstanceId: "work/codex", remote: "local") {
          providers { instanceId availability probedAt models { id label sources reasoningEfforts serviceTiers modes observedAt } }
        }
        providers { providers { driver } }
        provider(instanceId: "work/codex") { provider { origin { remote } builtIn } }
      }
      """, provider: provider)
    let calls = await provider.calls
    XCTAssertEqual(calls, ["catalog:work/codex:local", "providers:", "provider:work/codex:"])
    XCTAssertNil(result.body["errors"])
    guard case let .object(data)? = result.body["data"],
      case let .object(catalog)? = data["modelCatalog"],
      case let .array(rows)? = catalog["providers"],
      case let .object(row)? = rows.first,
      case let .array(models)? = row["models"] else {
      return XCTFail("Expected a projected catalog provider and model list")
    }
    XCTAssertEqual(row["instanceId"], .string("work/codex"))
    XCTAssertEqual(row["availability"], .null)
    XCTAssertEqual(row["probedAt"], .null)
    XCTAssertEqual(models.first, .object([
      "id": .string("default"), "label": .null, "sources": .array([.string("manifest")]), "reasoningEfforts": .array([]),
      "serviceTiers": .array([]), "modes": .array([]), "observedAt": .null
    ]))
    XCTAssertEqual(data["providers"], .object(["providers": .array([.object(["driver": .string("codex-agent")])])]))
    XCTAssertEqual(data["provider"], .object([
      "provider": .object(["origin": .object(["remote": .string("local")]), "builtIn": .bool(false)])
    ]))
  }

  func testMutationFieldsReachProviderAndProjectPayloads() async {
    let provider = RecordingBotsProvider()
    let result = await execute("""
      mutation {
        refreshProviders(input: {instanceId: "work/codex"}) { providers { instanceId } }
        saveProviderInstance(input: {instanceId: "work/codex", driver: "codex-agent", customModels: ["x"]}) {
          provider { instanceId }
        }
        removeProviderInstance(input: {instanceId: "work/codex", remote: "local"}) { providers { instanceId } }
      }
      """, provider: provider)
    let calls = await provider.calls
    XCTAssertEqual(calls, ["refresh:work/codex", "save:work/codex:codex-agent:x", "remove:work/codex:local"])
    let row: JSONValue = .object(["instanceId": .string("work/codex")])
    XCTAssertEqual(result.body["data"], .object([
      "refreshProviders": .object(["providers": .array([row])]),
      "saveProviderInstance": .object(["provider": row]),
      "removeProviderInstance": .object(["providers": .array([])])
    ]))
  }

  private func execute(_ query: String, provider: RecordingBotsProvider) async -> GraphQLDocumentExecutionResponse {
    await BotsGraphQLDocumentExecutor(provider: provider).execute(
      GraphQLDocumentRequest(query: query, environment: [:], isLocallyTrusted: true)
    )
  }
}

extension RecordingBotsProvider {
  func modelCatalog(providerInstanceId: String?, remote: String?) async throws -> ModelCatalogPayload {
    recordCatalogCall("catalog:\(providerInstanceId ?? ""):\(remote ?? "")")
    return ModelCatalogPayload(providers: catalogRows())
  }

  func providers(remote: String?) async throws -> ProviderListPayload {
    recordCatalogCall("providers:\(remote ?? "")")
    return ProviderListPayload(providers: catalogRows())
  }

  func provider(instanceId: String, remote: String?) async throws -> ProviderPayload {
    recordCatalogCall("provider:\(instanceId):\(remote ?? "")")
    return ProviderPayload(provider: try XCTUnwrap(catalogRows().first))
  }

  func refreshProviders(input: RefreshProvidersInput) async throws -> ProviderListPayload {
    recordCatalogCall("refresh:\(input.instanceId ?? "")")
    return ProviderListPayload(providers: catalogRows())
  }

  func saveProviderInstance(input: SaveProviderInstanceInput) async throws -> ProviderPayload {
    recordCatalogCall("save:\(input.instanceId):\(input.driver ?? ""):\(input.customModels?.joined(separator: ",") ?? "")")
    return ProviderPayload(provider: try XCTUnwrap(catalogRows().first))
  }

  func removeProviderInstance(input: RemoveProviderInstanceInput) async throws -> ProviderListPayload {
    recordCatalogCall("remove:\(input.instanceId):\(input.remote ?? "")")
    return ProviderListPayload(providers: [])
  }

  private func catalogRows() -> [GraphQLProviderInstance] {
    let origin = BotOrigin.local(serverId: nil, serverName: nil, at: Date(timeIntervalSince1970: 0))
    let instance = ProviderInstance(instanceId: "work/codex", driver: .codexAgent)
    return ModelCatalog.build(instances: [instance], reports: [:]).map { GraphQLProviderInstance($0, origin: origin) }
  }
}
