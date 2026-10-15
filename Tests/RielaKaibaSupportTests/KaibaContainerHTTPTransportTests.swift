import Foundation
import KaibaClient
import RielaCore
import XCTest
@testable import RielaKaibaSupport

final class KaibaContainerHTTPTransportTests: XCTestCase {
  func testGuestCannotChangeHostDestinationOrCredential() async throws {
    let spy = KaibaBridgeRecordingTransport(response: .init(statusCode: 200, body: Data(#"{"data":{"fixture":"ok"}}"#.utf8)))
    let instance = fixtureInstance()
    let host = try KaibaContainerHostTransport(instance: instance, environment: ["TOKEN": "host-secret"], transport: spy)
    let factory = KaibaContainerGuestTransport.clientFactory { encoded, deadline in
      XCTAssertFalse(encoded.contains("guest-secret"))
      var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
      object["url"] = "https://must-not-connect.example/graphql"
      object["headers"] = ["authorization": "Bearer guest-secret"]
      let modified = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
      return try await host.send(modified, deadline: deadline)
    }
    let client = try factory.makeClient(instance: instance, environment: ["TOKEN": "guest-secret"])
    _ = try await client.execute(.init(document: "query { fixture }"))
    let requests = await spy.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.url.absoluteString, "http://127.0.0.1:8787/graphql")
    XCTAssertEqual(request.headers["authorization"], "Bearer host-secret")
  }

  func testHostRejectsRemoteDestinationsExpiredRequestsAndOversizedBounds() async throws {
    let spy = KaibaBridgeRecordingTransport(response: .init(statusCode: 200, body: Data()))
    var instance = fixtureInstance()
    instance.endpoint = "https://remote.example/graphql"
    XCTAssertThrowsError(try KaibaContainerHostTransport(instance: instance, environment: ["TOKEN": "secret"], transport: spy))
    let host = try KaibaContainerHostTransport(instance: fixtureInstance(), environment: ["TOKEN": "secret"], transport: spy)
    for (bound, deadline) in [(0, Date().addingTimeInterval(10)), (Int.max, Date().addingTimeInterval(10)), (100, Date.distantPast)] {
      let data = try JSONSerialization.data(withJSONObject: ["body": Data("{}".utf8).base64EncodedString(), "maximumResponseBytes": bound])
      let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
      do {
        _ = try await host.send(encoded, deadline: deadline)
        XCTFail("host must reject an invalid transport budget")
      } catch is AdapterExecutionError { /* Expected before network I/O. */ }
    }
    let requests = await spy.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testAuthenticationStatusAndSanitizedGraphQLErrorsReachGuest() async throws {
    for (status, body) in [(401, "credential details"), (200, #"{"errors":[{"message":"host-secret was refused"}]}"#)] {
      let spy = KaibaBridgeRecordingTransport(response: .init(statusCode: status, body: Data(body.utf8)))
      let host = try KaibaContainerHostTransport(instance: fixtureInstance(), environment: ["TOKEN": "host-secret"], transport: spy)
      let factory = KaibaContainerGuestTransport.clientFactory { encoded, deadline in
        try await host.send(encoded, deadline: deadline)
      }
      let client = try factory.makeClient(instance: fixtureInstance(), environment: ["TOKEN": "guest-placeholder"])
      do {
        _ = try await client.execute(.init(document: "query { fixture }"))
        XCTFail("guest must retain the failure")
      } catch let error as KaibaClientError {
        if status == 401 {
          XCTAssertEqual(error, .authFailed(401))
        } else if case let .graphqlFailed(errors, _) = error {
          XCTAssertFalse(try XCTUnwrap(errors.first).message.contains("host-secret"))
        } else { XCTFail("expected a GraphQL error") }
      }
    }
  }

  private func fixtureInstance() -> KaibaInstance {
    .init(name: "Fixture", endpoint: "http://127.0.0.1:8787", authentication: .bearer(environmentVariable: "TOKEN"), isDefault: true)
  }
}

private actor KaibaBridgeRecordingTransport: KaibaHTTPTransporting {
  let response: KaibaHTTPResponse
  var requests: [KaibaHTTPRequest] = []
  init(response: KaibaHTTPResponse) { self.response = response }
  func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
    requests.append(request)
    return response
  }
}
