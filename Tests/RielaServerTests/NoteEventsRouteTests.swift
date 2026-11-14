import Foundation
import RielaCore
import RielaNote
import XCTest
@testable import RielaServer

final class NoteEventsRouteTests: XCTestCase {
  func testRouteIsNotFoundWhenNoFeedIsConfigured() async {
    let handler = DeterministicServerRouteHandler(allowUnauthenticatedNoteAPI: true)
    let response = await handler.route(.init(method: "GET", path: "/note/events"), context: .init())
    XCTAssertEqual(response.status, 404)
  }

  func testRouteRejectsUnauthenticatedRequestsWhenAuthIsConfigured() async throws {
    let fixture = try makeFixture()
    let response = await fixture.handler.route(
      .init(method: "GET", path: "/note/events", query: "since=0&timeoutMs=10"),
      context: .init()
    )
    XCTAssertEqual(response.status, 401)
  }

  func testRouteReturnsPublishedEventsToAnAuthenticatedClient() async throws {
    let fixture = try makeFixture()
    let token = try await register(with: fixture)
    await fixture.feed.publish(NoteChangeEvent(
      kind: NoteChangeEventKind.notebookProgress,
      notebookId: "nb-1",
      tagNames: ["proj/alpha"]
    ))

    let response = await fixture.handler.route(
      .init(
        method: "GET",
        path: "/note/events",
        headers: ["Authorization": "Bearer \(token)"],
        query: "since=0&timeoutMs=30000"
      ),
      context: .init()
    )

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body["revision"], .integer(1))
    XCTAssertEqual(response.body["events"], .array([
      .object([
        "kind": .string(NoteChangeEventKind.notebookProgress),
        "notebookId": .string("nb-1"),
        "tagNames": .array([.string("proj/alpha")])
      ])
    ]))
  }

  func testRouteHonoursTheSinceCursorAndTimesOutWithNoEvents() async throws {
    let fixture = try makeFixture()
    let token = try await register(with: fixture)
    await fixture.feed.publish(NoteChangeEvent(kind: NoteChangeEventKind.statusSets))

    let response = await fixture.handler.route(
      .init(
        method: "GET",
        path: "/note/events",
        headers: ["Authorization": "Bearer \(token)"],
        query: "since=1&timeoutMs=50"
      ),
      context: .init()
    )

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body["revision"], .integer(1))
    XCTAssertEqual(response.body["events"], .array([]))
  }

  func testNonGETMethodsOnTheEventsPathAreRejected() async {
    let feed = NoteChangeFeed()
    let handler = DeterministicServerRouteHandler(
      allowUnauthenticatedNoteAPI: true,
      noteChangeFeed: feed
    )
    let response = await handler.route(.init(method: "POST", path: "/note/events"), context: .init())
    XCTAssertEqual(response.status, 405)
  }

  func testQueryParametersAreDecodedFromTheRequestTarget() {
    let envelope = ServerRequestEnvelope(
      method: "GET",
      path: "/note/events",
      query: "since=42&timeoutMs=1000&tag=proj%2Falpha"
    )
    XCTAssertEqual(envelope.queryParameters["since"], "42")
    XCTAssertEqual(envelope.queryParameters["timeoutMs"], "1000")
    XCTAssertEqual(envelope.queryParameters["tag"], "proj/alpha")
    XCTAssertTrue(ServerRequestEnvelope(method: "GET", path: "/note/events").queryParameters.isEmpty)
  }

  // MARK: - Fixture

  private struct Fixture {
    var service: NoteService
    var authenticator: QRClientRegistrationAuthenticator
    var handler: DeterministicServerRouteHandler
    var feed: NoteChangeFeed
  }

  private func makeFixture(function: String = #function) throws -> Fixture {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/NoteEventsRouteTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let feed = NoteChangeFeed()
    let service = try NoteService(
      driver: SQLiteNoteDatabaseDriver(noteRoot: root.path),
      changeObserver: NoteChangeFeedObserver(feed: feed)
    )
    let authenticator = QRClientRegistrationAuthenticator(
      service: service,
      registrationScope: root.standardizedFileURL.path
    )
    return Fixture(
      service: service,
      authenticator: authenticator,
      handler: DeterministicServerRouteHandler(
        noteAPIAuthenticator: authenticator,
        noteChangeFeed: feed
      ),
      feed: feed
    )
  }

  private func register(with fixture: Fixture) async throws -> String {
    let challenge = try await fixture.authenticator.createRegistrationChallenge(
      publicBaseURL: "https://mac.example:8787"
    )
    let registration = await fixture.handler.route(
      .init(
        method: "POST",
        path: "/note/register",
        body: Data(#"{"code":"\#(challenge.code)","displayName":"iPad"}"#.utf8)
      ),
      context: .init()
    )
    XCTAssertEqual(registration.status, 200)
    guard case let .object(credential)? = registration.body["credential"],
          case let .string(token)? = credential["bearerToken"] else {
      throw XCTSkip("registration response did not carry a credential token")
    }
    return token
  }
}
