import Foundation
import RielaCore
import RielaGraphQL
import RielaNote
import XCTest
@testable import RielaServer

final class NoteAPIAuthTests: XCTestCase {
  func testNoteGraphQLRequiresRegisteredBearerWhenNoteAPIAuthIsEnabled() async throws {
    let fixture = try makeFixture()
    let createBody = noteCreateBody(title: "Remote Note")

    let unauthenticated = await fixture.handler.route(
      .init(method: "POST", path: "/graphql", body: createBody),
      context: .init()
    )
    XCTAssertEqual(unauthenticated.status, 401)

    let challenge = try await fixture.authenticator.createRegistrationChallenge(publicBaseURL: "https://mac.example:8787")
    XCTAssertTrue(challenge.registrationURL.contains("/note/register?code=\(challenge.code)"))
    let registration = await fixture.handler.route(
      .init(
        method: "POST",
        path: "/note/register",
        body: Data(#"{"code":"\#(challenge.code)","displayName":"iPad"}"#.utf8)
      ),
      context: .init()
    )
    XCTAssertEqual(registration.status, 200)
    let token = try credentialToken(registration.body)
    XCTAssertTrue(token.hasPrefix("rn_"))
    XCTAssertEqual(token.count, 46)

    let authenticated = await fixture.handler.route(
      .init(
        method: "POST",
        path: "/graphql",
        headers: ["Authorization": "Bearer \(token)"],
        body: createBody
      ),
      context: .init()
    )
    XCTAssertEqual(authenticated.status, 200)
    let createPayload = try graphQLPayload(authenticated.body, field: "createNote")
    XCTAssertEqual(try resultObject(createPayload)["accepted"], .bool(true))
    let createdNote = try objectValue(createPayload["note"], field: "note")
    let tagAssignments = try arrayValue(createdNote["tags"], field: "note.tags")

    let client = try XCTUnwrap(try fixture.service.listAPIClients().first)
    XCTAssertEqual(client.displayName, "iPad")
    XCTAssertNotNil(client.lastSeenAt)
    let firstTagAssignment = try objectValue(tagAssignments.first, field: "note.tags[0]")
    XCTAssertEqual(firstTagAssignment["assignedBy"], .string("client:\(client.clientId)"))

    _ = try fixture.service.revokeAPIClient(clientId: client.clientId)
    let revoked = await fixture.handler.route(
      .init(
        method: "POST",
        path: "/graphql",
        headers: ["Authorization": "Bearer \(token)"],
        body: createBody
      ),
      context: .init()
    )
    XCTAssertEqual(revoked.status, 401)
  }

  func testNoteRegistrationRouteDoesNotCreatePublicChallenges() async throws {
    let fixture = try makeFixture()
    let challengeResponse = await fixture.handler.route(
      .init(
        method: "GET",
        path: "/note/register",
        headers: [
          "Host": "mac.example:8787",
          "X-Forwarded-Proto": "https"
        ]
      ),
      context: .init()
    )

    XCTAssertEqual(challengeResponse.status, 403)
    XCTAssertEqual(
      challengeResponse.body["error"],
      .string("registration challenge creation requires an operator-controlled request")
    )

    let challenge = try await fixture.authenticator.createRegistrationChallenge(publicBaseURL: "https://mac.example:8787")

    let registration = await fixture.handler.route(
      .init(
        method: "POST",
        path: "/note/register",
        body: Data(#"{"code":"\#(challenge.code)","displayName":"Phone"}"#.utf8)
      ),
      context: .init()
    )

    XCTAssertEqual(registration.status, 200)
    let token = try credentialToken(registration.body)
    XCTAssertTrue(token.hasPrefix("rn_"))
    XCTAssertEqual(token.count, 46)
  }

  func testRegistrationCodesAreSingleUseAndExpire() async throws {
    let fixture = try makeFixture(ttlSeconds: 60)
    let challenge = try await fixture.authenticator.createRegistrationChallenge(publicBaseURL: "https://mac.example:8787")

    let first = try await fixture.authenticator.redeemRegistrationCode(code: challenge.code, displayName: "Phone")
    XCTAssertEqual(first.displayName, "Phone")
    XCTAssertTrue(first.bearerToken.hasPrefix("rn_"))
    XCTAssertEqual(first.bearerToken.count, 46)
    do {
      _ = try await fixture.authenticator.redeemRegistrationCode(code: challenge.code, displayName: "Replay")
      XCTFail("expected single-use registration code rejection")
    } catch {
      XCTAssertTrue(String(describing: error).contains("registration code not found"))
    }

    fixture.clock.date = fixture.clock.date.addingTimeInterval(120)
    let expired = try await fixture.authenticator.createRegistrationChallenge(publicBaseURL: "https://mac.example:8787")
    fixture.clock.date = fixture.clock.date.addingTimeInterval(120)
    do {
      _ = try await fixture.authenticator.redeemRegistrationCode(code: expired.code, displayName: "Late")
      XCTFail("expected expired registration code rejection")
    } catch {
      XCTAssertTrue(String(describing: error).contains("registration code expired"))
    }
  }

  func testRegistrationChallengesAreBoundedAndExpiredCodesArePruned() async throws {
    let fixture = try makeFixture(ttlSeconds: 60)
    for _ in 0..<QRClientRegistrationAuthenticator.maximumPendingRegistrationCodes {
      _ = try await fixture.authenticator.createRegistrationChallenge(publicBaseURL: "https://mac.example:8787")
    }
    do {
      _ = try await fixture.authenticator.createRegistrationChallenge(publicBaseURL: "https://mac.example:8787")
      XCTFail("expected pending registration code cap")
    } catch {
      XCTAssertTrue(String(describing: error).contains("too many pending registration codes"))
    }

    fixture.clock.date = fixture.clock.date.addingTimeInterval(120)
    let pruned = try await fixture.authenticator.createRegistrationChallenge(publicBaseURL: "https://mac.example:8787")
    XCTAssertTrue(pruned.registrationURL.contains("/note/register?code=\(pruned.code)"))
  }

  func testRegistrationChallengeCannotBeRedeemedByDifferentNoteRootScope() async throws {
    let store = NoteAPIRegistrationChallengeStore()
    let firstRoot = try temporaryNoteRoot(name: "first")
    let secondRoot = try temporaryNoteRoot(name: "second")
    let firstService = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: firstRoot.path))
    let secondService = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: secondRoot.path))
    let firstAuthenticator = QRClientRegistrationAuthenticator(
      service: firstService,
      registrationScope: firstRoot.standardizedFileURL.path,
      challengeStore: store,
      randomData: DeterministicBytes().data(byteCount:)
    )
    let secondAuthenticator = QRClientRegistrationAuthenticator(
      service: secondService,
      registrationScope: secondRoot.standardizedFileURL.path,
      challengeStore: store,
      randomData: DeterministicBytes().data(byteCount:)
    )
    let challenge = try await firstAuthenticator.createRegistrationChallenge(publicBaseURL: "https://first.example")

    do {
      _ = try await secondAuthenticator.redeemRegistrationCode(code: challenge.code, displayName: "Wrong")
      XCTFail("expected cross-scope registration rejection")
    } catch {
      XCTAssertTrue(String(describing: error).contains("registration code not found"))
    }

    let credential = try await firstAuthenticator.redeemRegistrationCode(code: challenge.code, displayName: "Right")
    XCTAssertEqual(credential.displayName, "Right")
    XCTAssertEqual(try firstService.listAPIClients().map(\.displayName), ["Right"])
    XCTAssertEqual(try secondService.listAPIClients(), [])
  }

  private func makeFixture(ttlSeconds: Int = 300, function: String = #function) throws -> NoteAPITestFixture {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/NoteAPIAuthTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let bytes = DeterministicBytes()
    let clock = MutableClock(date: Date(timeIntervalSince1970: 1_800_000_000))
    let authenticator = QRClientRegistrationAuthenticator(
      service: service,
      registrationScope: root.standardizedFileURL.path,
      ttlSeconds: ttlSeconds,
      challengeStore: NoteAPIRegistrationChallengeStore(),
      timeProvider: NoteAPITimeProvider(now: { clock.date }),
      randomData: bytes.data(byteCount:)
    )
    let handler = DeterministicServerRouteHandler(
      graphQLExecutor: NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(service: service)),
      noteAPIAuthenticator: authenticator
    )
    return NoteAPITestFixture(
      service: service,
      authenticator: authenticator,
      handler: handler,
      clock: clock
    )
  }

  private func temporaryNoteRoot(name: String, function: String = #function) throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/NoteAPIAuthTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(name, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func noteCreateBody(title: String) -> Data {
    Data("""
    {
      "query": "mutation CreateNote($input: CreateNoteInput!) { createNote(input: $input) { result { accepted status } note { noteId title tags { assignedBy tag { name } } } } }",
      "variables": {
        "input": {
          "bodyMarkdown": "# \(title)\\n\\nRemote body",
          "tags": [{ "name": "remote-client" }]
        }
      },
      "operationName": "CreateNote"
    }
    """.utf8)
  }

  private func credentialToken(_ body: JSONObject) throws -> String {
    try stringValue(try objectValue(body["credential"], field: "credential")["bearerToken"], field: "bearerToken")
  }

  private func graphQLPayload(_ body: JSONObject, field: String) throws -> JSONObject {
    let data = try objectValue(body["data"], field: "data")
    return try objectValue(data[field], field: field)
  }

  private func resultObject(_ payload: JSONObject) throws -> JSONObject {
    try objectValue(payload["result"], field: "result")
  }

  private func objectValue(_ value: JSONValue?, field: String) throws -> JSONObject {
    guard case let .object(object)? = value else {
      XCTFail("expected \(field) object")
      return [:]
    }
    return object
  }

  private func arrayValue(_ value: JSONValue?, field: String) throws -> [JSONValue] {
    guard case let .array(array)? = value else {
      XCTFail("expected \(field) array")
      return []
    }
    return array
  }

  private func stringValue(_ value: JSONValue?, field: String) throws -> String {
    guard case let .string(string)? = value else {
      XCTFail("expected \(field) string")
      return ""
    }
    return string
  }
}

private struct NoteAPITestFixture {
  var service: NoteService
  var authenticator: QRClientRegistrationAuthenticator
  var handler: DeterministicServerRouteHandler
  var clock: MutableClock
}

private final class MutableClock: @unchecked Sendable {
  var date: Date

  init(date: Date) {
    self.date = date
  }
}

private final class DeterministicBytes: @unchecked Sendable {
  private var next: UInt8 = 1

  func data(byteCount: Int) -> Data {
    defer { next = next &+ 1 }
    return Data(repeating: next, count: byteCount)
  }
}
