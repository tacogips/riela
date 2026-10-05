#if os(macOS)
import Foundation
import RielaServer

private struct APIKeyManagementInput: Decodable {
  let expectedProfile: String?
  let name: String?
  let purpose: RielaAPIKeyStore.Purpose?
  let workerID: String?
  let expiresAt: Date?
  let id: String?
  let requireClientKey: Bool?
}

extension RielaApp {
  var apiKeyStore: RielaAPIKeyStore {
    RielaAPIKeyStore(root: profileStore.appRootURL.appendingPathComponent("api-auth", isDirectory: true))
  }

  /// Called exclusively from the inherited desktop IPC channel.
  func apiKeyManagementResponse(for request: RielaHTTPRequest) -> RielaHTTPResponse {
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let data: Data
      if request.method == "GET" {
        struct Snapshot: Encodable {
          let profile: String
          let requireClientKey: Bool
          let keys: [RielaAPIKeyStore.Record]
        }
        data = try encoder.encode(Snapshot(profile: daemonProfileName.rawValue, requireClientKey: apiKeyStore.requireClientKey(), keys: apiKeyStore.list()))
      } else {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let input = try decoder.decode(APIKeyManagementInput.self, from: request.body)
        guard input.expectedProfile == daemonProfileName.rawValue else {
          return .text(status: 409, "The active profile changed. Refresh API keys before saving.")
        }
        switch request.method {
        case "POST":
          guard let name = input.name, let purpose = input.purpose else { return .text(status: 400, "Name and purpose are required.") }
          if purpose == .worker {
            let config = try DistributedControllerConfiguration.load(from: distributedControllerConfigurationURL)
            guard config.workers.contains(where: { $0.id == input.workerID }) else {
              return .text(status: 400, "Save the worker in controller settings before issuing its key.")
            }
          }
          let issued = try apiKeyStore.issue(name: name, purpose: purpose, workerID: input.workerID, expiresAt: input.expiresAt)
          struct Issued: Encodable { let token: String; let record: RielaAPIKeyStore.Record }
          data = try encoder.encode(Issued(token: issued.token, record: issued.record))
        case "PUT":
          guard let required = input.requireClientKey else { return .text(status: 400, "Authentication policy is required.") }
          try apiKeyStore.setRequireClientKey(required)
          data = Data("{}".utf8)
        case "DELETE":
          guard let id = input.id else { return .text(status: 400, "Key ID is required.") }
          try apiKeyStore.revoke(id: id)
          data = Data("{}".utf8)
        default:
          return .text(status: 405, "Method not allowed")
        }
      }
      return RielaHTTPResponse(status: 200, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: data)
    } catch {
      return .text(status: 400, "Cannot update API keys. Check the name, expiration, worker and authentication store.")
    }
  }
}
#endif
