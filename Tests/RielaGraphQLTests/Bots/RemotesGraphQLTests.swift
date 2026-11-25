import Foundation
import RielaCore
import RielaGraphQL
import XCTest

final class RemotesGraphQLTests: XCTestCase {
  func testRegistryRootsDecodeInputsAndProjectTheRegistry() async {
    let provider = RecordingBotsProvider()
    let executor = BotsGraphQLDocumentExecutor(provider: provider)
    let operations = [
      ("{ result: remotes { active remotes { name address serverName scope lastSeenAt connection } } }", "local"),
      (#"mutation { result: addRemote(input: {name: "srv", code: "fixture-code", clientName: "client"}) { active } }"#, "local"),
      (#"mutation { result: removeRemote(input: {name: "srv"}) { active } }"#, "local"),
      (#"mutation { result: useRemote(input: {name: "srv"}) { active } }"#, "srv")
    ]
    for (query, active) in operations {
      let response = await executor.execute(.init(query: query, environment: [:], isLocallyTrusted: true))
      var payload: JSONObject = ["active": .string(active)]
      if query.contains("result: remotes") {
        payload["remotes"] = .array([.object([
          "name": .string("srv"), "address": .string("https://riela.example"), "serverName": .string("Riela"),
          "scope": .string("read"), "lastSeenAt": .string("1970-01-01T00:00:00Z"), "connection": .string("connected")
        ])])
      }
      XCTAssertNil(response.body["errors"])
      XCTAssertEqual(response.body["data"], .object(["result": .object(payload)]))
    }
    let calls = await provider.calls
    XCTAssertEqual(calls, ["remotes", "addRemote:srv:fixture-code:client", "removeRemote:srv", "useRemote:srv"])
  }
}

extension RecordingBotsProvider {
  func remotes() async throws -> RemoteListPayload {
    recordCatalogCall("remotes")
    let record = RemoteSummary(
      name: "srv", address: "https://riela.example", serverName: "Riela", scope: "read",
      lastSeenAt: Date(timeIntervalSince1970: 0), connection: .connected
    )
    return .init(active: "local", remotes: [record])
  }

  func addRemote(input: AddRemoteInput) async throws -> RemoteListPayload {
    recordCatalogCall("addRemote:\(input.name):\(input.code):\(input.clientName ?? "")")
    return .init(active: "local", remotes: [])
  }

  func removeRemote(input: RemoveRemoteInput) async throws -> RemoteListPayload {
    recordCatalogCall("removeRemote:\(input.name)")
    return .init(active: "local", remotes: [])
  }

  func useRemote(input: UseRemoteInput) async throws -> RemoteListPayload {
    recordCatalogCall("useRemote:\(input.name)")
    return .init(active: input.name, remotes: [])
  }
}
