import AppCore
import Foundation
import RielaAddonSupport
import RielaCore
import XCTest
@testable import RielaKaibaAddons

/// `kaiba serve` authenticates by default, so the node that talks to it —
/// `kaiba/note-graphql-remote` — decides up front whether it holds a
/// credential, and it opens no local store at all. The local library nodes stay
/// unauthenticated and are covered by the other kaiba add-on tests.
final class KaibaEndpointAuthTests: XCTestCase {
  func testRemoteNodeRefusesToCallAServerWithoutACredential() async throws {
    do {
      _ = try await executeRemote(environment: [:], config: [
        "endpoint": .string("http://127.0.0.1:9"),
        "query": .string("query { notebooks(limit: 1) { result { accepted } } }")
      ])
      XCTFail("expected the missing credential to be refused before the request")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      XCTAssertTrue(error.message.contains("KAIBA_API_KEY"), error.message)
    }
  }

  func testRemoteNodeReadsTheKeyFromTheConfiguredEnvironmentVariable() async throws {
    do {
      // Port 9 (discard) refuses immediately: the point is that the node got
      // past its credential check and attempted the call.
      _ = try await executeRemote(environment: ["KAIBA_STAGING_KEY": "staging-token"], config: [
        "endpoint": .string("http://127.0.0.1:9"),
        "apiKeyEnv": .string("KAIBA_STAGING_KEY"),
        "query": .string("query { notebooks(limit: 1) { result { accepted } } }")
      ])
      XCTFail("expected the unreachable endpoint to fail the request")
    } catch let error as AdapterExecutionError {
      XCTAssertFalse(error.message.contains("KAIBA_STAGING_KEY"), error.message)
    }
  }

  func testAllowUnauthenticatedOptsIntoAKeylessRequest() async throws {
    do {
      _ = try await executeRemote(environment: [:], config: [
        "endpoint": .string("http://127.0.0.1:9"),
        "allowUnauthenticated": .bool(true),
        "query": .string("query { notebooks(limit: 1) { result { accepted } } }")
      ])
      XCTFail("expected the unreachable endpoint to fail the request")
    } catch let error as AdapterExecutionError {
      XCTAssertFalse(error.message.contains("KAIBA_API_KEY"), error.message)
    }
  }

  func testRemoteNodeRequiresAnEndpoint() async throws {
    do {
      _ = try await executeRemote(environment: [:], config: [
        "query": .string("query { notebooks(limit: 1) { result { accepted } } }")
      ])
      XCTFail("expected the missing endpoint to be rejected")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      XCTAssertTrue(error.message.contains("endpoint is required"), error.message)
    }
  }

  /// The local node never speaks HTTP: an `endpoint` on it is a misrouted node,
  /// not a mode switch, so it names the remote node instead of silently
  /// reading the local store.
  func testLocalDocumentNodeRejectsAnEndpoint() async throws {
    let root = scratchNoteRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    do {
      _ = try await KaibaAddonCatalog.execute(
        WorkflowAddonExecutionInput(
          workflowId: "kaiba-endpoint-auth-test",
          stepId: "local",
          nodeId: "local",
          addon: WorkflowNodeAddonRef(
            name: "kaiba/note-graphql-document",
            version: "1",
            config: [
              "noteRoot": .string(root.path),
              "endpoint": .string("http://127.0.0.1:9"),
              "query": .string("query { notebooks(limit: 1) { result { accepted } } }")
            ]
          ),
          resolvedInputPayload: [:]
        ),
        environment: [:]
      )
      XCTFail("expected the local node to refuse an endpoint")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      XCTAssertTrue(error.message.contains("kaiba/note-graphql-remote"), error.message)
    }
  }

  /// The remote node opens no note root, so it works on a host that has no
  /// kaiba store at all.
  func testRemoteNodeOpensNoLocalStore() async throws {
    let root = scratchNoteRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    do {
      _ = try await executeRemote(environment: ["KAIBA_API_KEY": "token"], config: [
        "noteRoot": .string(root.path),
        "endpoint": .string("http://127.0.0.1:9"),
        "query": .string("query { notebooks(limit: 1) { result { accepted } } }")
      ])
      XCTFail("expected the unreachable endpoint to fail the request")
    } catch is AdapterExecutionError {
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("note-store.sqlite").path),
        "the remote node must not create a local kaiba store"
      )
    }
  }

  private func executeRemote(
    environment: [String: String],
    config: JSONObject
  ) async throws -> AdapterExecutionOutput {
    try await KaibaAddonCatalog.execute(
      WorkflowAddonExecutionInput(
        workflowId: "kaiba-endpoint-auth-test",
        stepId: "endpoint",
        nodeId: "endpoint",
        addon: WorkflowNodeAddonRef(name: "kaiba/note-graphql-remote", version: "1", config: config),
        resolvedInputPayload: [:]
      ),
      environment: environment
    )
  }

  private func scratchNoteRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-kaiba-endpoint-auth-\(UUID().uuidString)", isDirectory: true)
  }
}
