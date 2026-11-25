import Foundation
import RielaCore
import RielaServer

struct RemoteGraphQLClient: Sendable {
  private struct Request: Encodable {
    let query: String
    let variables: JSONObject
    let operationName: String?
  }

  let record: RemoteRecord
  let token: String
  var transport: RemoteHTTP.Transport = RemoteHTTP.production

  func execute(query: String, variables: JSONObject = [:], operationName: String? = nil) async throws -> JSONObject {
    let endpoint = try RielaPairingAddress.validate(record.address)
    var request = try RemoteHTTP.post(endpoint: endpoint, path: "/graphql")
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONEncoder().encode(Request(query: query, variables: variables, operationName: operationName))
    let (data, status) = try await RemoteHTTP.send(request, via: transport)
    if status == 401 { throw Self.unauthorized }
    guard (200..<300).contains(status), let envelope = try? JSONDecoder().decode(JSONObject.self, from: data) else {
      throw RemoteHTTP.invalidResponse
    }
    if case let .array(errors)? = envelope["errors"], let error = errors.first {
      guard case let .object(issue) = error, case let .object(extensions)? = issue["extensions"],
            case let .string(code)? = extensions["code"] else { throw RemoteHTTP.invalidResponse }
      if code == "UNAUTHENTICATED" { throw Self.unauthorized }
      guard let safeCode = RemoteHTTP.safeErrorCode(code, authorization: request.value(forHTTPHeaderField: "Authorization"))
      else { throw RemoteHTTP.invalidResponse }
      throw BotStoreError(code: safeCode, message: "The remote GraphQL operation failed")
    }
    guard case let .object(result)? = envelope["data"] else { throw RemoteHTTP.invalidResponse }
    return result
  }

  private static var unauthorized: BotStoreError {
    BotStoreError(code: "remote_unauthorized", message: "The remote did not authorize the credential")
  }
}
