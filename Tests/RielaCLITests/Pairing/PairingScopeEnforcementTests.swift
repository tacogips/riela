import Foundation
import RielaCore
import RielaGraphQL
import RielaServer
import XCTest
@testable import RielaCLI

@MainActor
final class PairingScopeEnforcementTests: XCTestCase {
  private let pause = #"mutation { setBotPaused(input: {botId: "alpha", paused: true}) { bot { paused } origin { serverId } } }"#
  private let remove = #"mutation { removeBot(input: {botId: "alpha"}) { bot { botId } } }"#
  private let mint = #"mutation { mintPairingCode(input: {address: "https://riela.example", scope: "read"}) { scope } }"#
  private let list = "{ pairingGrants { grants { grantId } } }"

  func testReadAndOperateOnlyExecuteAllowedRoots() async throws {
    let fixture = try PairingServeFixture(test: self)
    try fixture.createBot()
    let store = fixture.pairing.store
    let read = try store.issue(name: "read", scope: .read).token
    let operate = try store.issue(name: "operate", scope: .operate).token
    let listed = try await fixture.graphql("{ bots { bots { bot { botId } } } }", token: read)
    let rows = listed["data"]?.pairingObject?["bots"]?.pairingObject?["bots"]?.pairingArray
    XCTAssertEqual(rows?.first?.pairingObject?["bot"]?.pairingObject?["botId"], .string("alpha"))
    let readPause = try await fixture.graphql(pause, token: read)
    XCTAssertEqual(PairingServeFixture.errorCode(readPause), "scope_insufficient")
    let paused = try await fixture.graphql(pause, token: operate)
    let result = paused["data"]?.pairingObject?["setBotPaused"]?.pairingObject
    XCTAssertEqual(result?["bot"]?.pairingObject?["paused"], .bool(true))
    XCTAssertEqual(result?["origin"]?.pairingObject?["serverId"], .string(fixture.pairing.identity.serverId))
    let saveProvider = #"mutation { saveProviderInstance(input: {instanceId: "custom", driver: "codex"}) { provider { instanceId } } }"#
    for forbidden in [remove, mint, saveProvider, list, "{"] {
      let response = try await fixture.graphql(forbidden, token: operate)
      XCTAssertEqual(PairingServeFixture.errorCode(response), "scope_insufficient")
    }
  }

  func testAdminAndUnscopedClientKeysRetainAdminAuthority() async throws {
    let fixture = try PairingServeFixture(test: self)
    let store = fixture.pairing.store
    let admin = try store.issue(name: "admin", scope: .admin).token
    let legacy = try store.issue(name: "legacy").token
    for token in [admin, legacy] {
      try fixture.createBot()
      for query in [list, mint, remove] {
        let response = try await fixture.graphql(query, token: token)
        XCTAssertNotNil(response["data"]?.pairingObject)
        XCTAssertNil(PairingServeFixture.errorCode(response))
      }
    }
  }

  func testMixedOperationDocumentIsDeniedBeforeProviderCalls() async throws {
    let fixture = try PairingServeFixture(test: self)
    let store = fixture.pairing.store
    let token = try store.issue(name: "operate", scope: .operate).token
    let executor = PairingExecutionCounter()
    let authorization = APIKeyGraphQLAuthorization(store: store, next: executor)
    let request = GraphQLDocumentRequest(
      query: #"query Preview { bots { groups } } mutation Admin { renamed: removeBot(input: {botId: "alpha"}) { bot { botId } } }"#,
      operationName: "Preview", transportCredential: GraphQLTransportCredential(token)
    )
    let rejected = await authorization.execute(request)
    let errors = rejected.body["errors"]?.pairingArray
    XCTAssertEqual(PairingServeFixture.errorCode(rejected.body), "scope_insufficient")
    XCTAssertTrue(errors?.first?.pairingObject?["message"]?.pairingString?.contains("Mutation.removeBot") == true)
    let calls = await executor.calls
    XCTAssertEqual(calls, 0)
  }

  func testRevocationInterruptsHeldActivityWait() async throws {
    let fixture = try PairingServeFixture(test: self)
    try fixture.startSession()
    let store = fixture.pairing.store
    let code = try fixture.pairing.mint(address: "https://riela.example", scope: .read)
    let decoded = try PairingServeFixture.pairingEnvelope(code.code)
    let issued = try store.redeemPairingCode(secret: XCTUnwrap(decoded["secret"]), clientName: "reader", now: Date())
    let query = #"{ botActivity(sessionId: "session", waitMs: 25000) { lastSequence } }"#
    let clock = ContinuousClock()
    let started = clock.now
    async let response = fixture.graphql(query, token: issued.token)
    try await Task.sleep(for: .milliseconds(300))
    let grants = try store.pairingGrants()
    XCTAssertNotNil(grants.first?.lastUsedAt, "The held request must enter the native executor before revocation")
    _ = try fixture.pairing.revoke(grantId: issued.record.id)
    let result = try await response
    XCTAssertEqual(PairingServeFixture.errorCode(result), "UNAUTHENTICATED")
    XCTAssertLessThan(started.duration(to: clock.now), .seconds(2))
  }
}

private actor PairingExecutionCounter: GraphQLDocumentExecuting {
  private(set) var calls = 0

  func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    calls += 1
    return .notHandled
  }
}
