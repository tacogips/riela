import Foundation
import XCTest
import RielaCore
@testable import RielaCLI

#if canImport(WrikeGatewayCore)
import WrikeGatewayCore
import WrikeGatewayRead

final class SpecialistWrikeReaderTests: XCTestCase {
  func testProductionDocumentExecutesAgainstActualGatewaySchema() async throws {
    let transport = SchemaTransport()
    let executor = CapabilityExecutor(planner: CapabilityPlanner(registry: try ReadCapabilities.registry()),
                                      transport: transport, credentials: SchemaCredentials())
    let response = await GraphQLRuntime(executor: executor).execute(
      document: SpecialistProductionWrikeReader.document,
      variables: ["folderId": .string("IEAAAAAAI4AB5FNY"), "cursor": .null]
    )
    XCTAssertTrue(response.errors.isEmpty, response.rendered(pretty: false))
    let count = await transport.count
    XCTAssertEqual(count, 1, "Valid gateway schema must reach the injected transport exactly once")
  }

  func testConnectionPaginationFindsUniqueReceiptOnLaterPage() async throws {
    let reader = ReaderFixture(pages: try [page([], next: "next"), page(["remote"])])
    let adapter = SpecialistWrikeGatewayAdapter(configuration: .init(folderId: "folder", statusByLifecycle: [:]), reader: reader)
    let result = try await adapter.reconcile(event, trackerTaskId: nil)
    XCTAssertEqual(result, .delivered("remote"))
    let cursors = await reader.cursors
    XCTAssertEqual(cursors, [nil, "next"])
  }

  func testLaterConflictDoesNotAcceptFirstPageReceipt() async throws {
    let reader = ReaderFixture(pages: try [page(["remote"], next: "next"), page(["other"])])
    let adapter = SpecialistWrikeGatewayAdapter(configuration: .init(folderId: "folder", statusByLifecycle: [:]), reader: reader)
    let result = try await adapter.reconcile(event, trackerTaskId: nil)
    XCTAssertEqual(result, .conflicting)
  }

  func testRepeatedCursorDoesNotProveUniqueReceipt() async throws {
    let reader = ReaderFixture(pages: try [page(["remote"], next: "loop")])
    let adapter = SpecialistWrikeGatewayAdapter(configuration: .init(folderId: "folder", statusByLifecycle: [:]), reader: reader)
    let result = try await adapter.reconcile(event, trackerTaskId: nil)
    XCTAssertEqual(result, .notFound)
    let cursors = await reader.cursors
    XCTAssertEqual(cursors.count, 2)
  }

  private var event: SpecialistOutboxEvent {
    .init(eventId: "event", taskId: "task", destination: "tracker", operation: "ownership", payload: "work", sequence: 1)
  }

  private func page(_ ids: [String], next: String? = nil) throws -> Data {
    let value: [String: Any] = ["tasks": [
      "nodes": ids.map { ["id": $0, "description": "[riela-correlation:event] work"] },
      "pageInfo": ["nextPageToken": next.map { $0 as Any } ?? NSNull()]
    ]]
    return try JSONSerialization.data(withJSONObject: value)
  }
}

private actor ReaderFixture: SpecialistWrikeReader {
  let pages: [Data]
  var cursors: [String?] = []

  init(pages: [Data]) { self.pages = pages }

  func tasks(folderId _: String, cursor: String?) async throws -> Data {
    let result = pages[min(cursors.count, pages.count - 1)]
    cursors.append(cursor)
    return result
  }
}

private actor SchemaTransport: WrikeTransport {
  var count = 0
  func send(_: PreparedRequest) async throws -> WrikeResponse {
    count += 1
    return WrikeResponse(statusCode: 200, body: Data(#"{"kind":"tasks","data":[{"id":"IEAAAAAAI4AB5FNY","description":"fixture"}]}"#.utf8))
  }
}

private struct SchemaCredentials: CredentialProvider {
  func credential() async throws -> ResolvedCredential {
    ResolvedCredential(mode: .permanentToken, token: SecretValue("fixture"),
                       baseURL: try XCTUnwrap(URL(string: "https://www.wrike.com/api/v4")),
                       grantedScopes: ["wsReadOnly"], expiresAt: nil)
  }
  func refreshedCredential(after _: ResolvedCredential) async throws -> ResolvedCredential? { nil }
}
#endif
