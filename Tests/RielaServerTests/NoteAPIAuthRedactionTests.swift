import Foundation
import RielaCore
import RielaGraphQL
import RielaNote
import XCTest
@testable import RielaServer

/// Verifies that internal storage errors surfacing during authentication or
/// registration never leak raw paths, SQL, or endpoint details to a client
/// response body (design theme T2, findings F24/F25).
final class NoteAPIAuthRedactionTests: XCTestCase {
  func testAuthenticateWithBrokenStoreReturnsFixedUnavailableMessage() async throws {
    let (service, authenticator, noteRoot) = try makeAuthenticator()

    // Register a client so a plausible bearer token exists, then break the store
    // so the subsequent authentication query fails inside SQLite.
    let credential = try service.registerAPIClient(displayName: "Phone", bearerToken: "rn_secret-token")
    XCTAssertFalse(credential.clientId.isEmpty)
    try service.driver.withDatabase { database in
      try database.execute("DROP TABLE api_clients")
    }

    let result = await authenticator.authenticate(
      request: ServerRequestEnvelope(method: "POST", path: "/graphql"),
      context: ServerRequestContext(bearerToken: "rn_secret-token")
    )

    guard case let .rejected(response) = result else {
      return XCTFail("expected rejected authentication result")
    }
    XCTAssertEqual(response.status, 503)
    let text = responseText(response.body)
    XCTAssertTrue(text.contains("note API authentication is unavailable"), text)
    assertRedacted(text, noteRoot: noteRoot)
  }

  func testRegistrationWithBrokenStoreReturnsFixedFailureMessage() async throws {
    let (service, authenticator, noteRoot) = try makeAuthenticator()

    let challenge = try await authenticator.createRegistrationChallenge(publicBaseURL: "https://example.test")
    try service.driver.withDatabase { database in
      try database.execute("DROP TABLE api_clients")
    }

    let response = await authenticator.redeemRegistrationCode(
      request: ServerRequestEnvelope(
        method: "POST",
        path: "/note/register",
        body: Data(#"{"code":"\#(challenge.code)","displayName":"Phone"}"#.utf8)
      ),
      context: ServerRequestContext()
    )

    XCTAssertEqual(response.status, 500)
    let text = responseText(response.body)
    XCTAssertTrue(text.contains("registration failed"), text)
    assertRedacted(text, noteRoot: noteRoot)
  }

  // MARK: - helpers

  private func makeAuthenticator(
    function: String = #function
  ) throws -> (NoteService, QRClientRegistrationAuthenticator, String) {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/NoteAPIAuthRedactionTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let authenticator = QRClientRegistrationAuthenticator(
      service: service,
      registrationScope: root.standardizedFileURL.path,
      challengeStore: NoteAPIRegistrationChallengeStore()
    )
    return (service, authenticator, root.standardizedFileURL.path)
  }

  private func responseText(_ body: JSONObject) -> String {
    guard let data = try? JSONEncoder().encode(JSONValue.object(body)),
          let text = String(data: data, encoding: .utf8) else {
      return ""
    }
    return text
  }

  private func assertRedacted(_ text: String, noteRoot: String, file: StaticString = #filePath, line: UInt = #line) {
    // No SQL keywords, table names, filesystem paths, or endpoint hints.
    for leak in ["SELECT", "INSERT", "UPDATE", "api_clients", "sqlite", ".db", noteRoot, "/tmp", "no such table"] {
      XCTAssertFalse(
        text.localizedCaseInsensitiveContains(leak),
        "response leaked '\(leak)': \(text)",
        file: file,
        line: line
      )
    }
  }
}
