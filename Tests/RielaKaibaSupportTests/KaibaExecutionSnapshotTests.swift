import Foundation
import KaibaClient
import XCTest
@testable import RielaKaibaSupport

final class KaibaExecutionSnapshotTests: XCTestCase {
  func testCapturesOneClientPerDistinctBindingAndRetainsDefaultResolution() throws {
    let defaultInstance = KaibaInstance(
      name: "Default",
      endpoint: "https://kaiba.example.test",
      authentication: .unauthenticated,
      isDefault: true,
      allowRemoteUnauthenticated: true
    )
    let secondaryInstance = KaibaInstance(
      name: "Secondary",
      endpoint: "https://secondary.example.test",
      authentication: .unauthenticated,
      allowRemoteUnauthenticated: true
    )
    let snapshot = try KaibaExecutionSnapshot(
      bindingIDs: [secondaryInstance.id, nil, secondaryInstance.id],
      catalog: .init(instances: [defaultInstance, secondaryInstance]),
      environment: [:],
      clientFactory: KaibaClientFactory(transportFactory: { SnapshotTransport() })
    )

    XCTAssertEqual(snapshot.clients.map(\.instance.id), [secondaryInstance.id, defaultInstance.id])
    XCTAssertEqual(try snapshot.client(bindingID: nil).instance.id, defaultInstance.id)
    XCTAssertEqual(
      try snapshot.client(bindingID: secondaryInstance.id).client.endpoint.description,
      "https://secondary.example.test/graphql"
    )
  }

  func testRejectsUnknownBindingBeforeAnyExecutionStarts() {
    let instance = KaibaInstance(
      name: "Default",
      endpoint: "https://kaiba.example.test",
      authentication: .unauthenticated,
      isDefault: true,
      allowRemoteUnauthenticated: true
    )

    XCTAssertThrowsError(try KaibaExecutionSnapshot(
      bindingIDs: ["00000000-0000-0000-0000-000000000000"],
      catalog: .init(instances: [instance]),
      environment: [:],
      clientFactory: KaibaClientFactory(transportFactory: { SnapshotTransport() })
    )) { error in
      XCTAssertEqual(error as? KaibaInstanceStoreError, .missingInstance)
    }
  }

  func testReadinessRunsOnceForEachCapturedClientInCaptureOrder() async throws {
    let first = KaibaInstance(
      name: "First",
      endpoint: "https://first.example.test",
      authentication: .unauthenticated,
      isDefault: true,
      allowRemoteUnauthenticated: true
    )
    let second = KaibaInstance(
      name: "Second",
      endpoint: "https://second.example.test",
      authentication: .unauthenticated,
      allowRemoteUnauthenticated: true
    )
    let snapshot = try KaibaExecutionSnapshot(
      bindingIDs: [second.id, nil, second.id],
      catalog: .init(instances: [first, second]),
      environment: [:],
      clientFactory: KaibaClientFactory(transportFactory: { SnapshotTransport() })
    )

    let results = try await snapshot.readiness()

    XCTAssertEqual(results.map(\.instanceID), [second.id, first.id])
    XCTAssertEqual(results.map(\.result.status), [.ready, .ready])
  }

  func testPreflightProbesLongTermMemoryOnlyForSelectedMemoryInstance() async throws {
    let memory = KaibaInstance(
      name: "Memory",
      endpoint: "https://memory.example.test",
      authentication: .unauthenticated,
      isDefault: true,
      allowRemoteUnauthenticated: true
    )
    let notes = KaibaInstance(
      name: "Notes",
      endpoint: "https://notes.example.test",
      authentication: .unauthenticated,
      allowRemoteUnauthenticated: true
    )
    let transport = RecordingSnapshotTransport()
    let requests = [
      KaibaExecutionSnapshot.BindingRequest(instanceID: memory.id, requiresLongTermMemory: true),
      KaibaExecutionSnapshot.BindingRequest(instanceID: notes.id)
    ]
    let snapshot = try KaibaExecutionSnapshot(
      requests: requests,
      catalog: .init(instances: [memory, notes]),
      environment: [:],
      clientFactory: KaibaClientFactory(transportFactory: { transport })
    )

    let results = try await snapshot.preflight(requests: requests)

    XCTAssertEqual(results.map(\.instanceID), [memory.id, notes.id])
    XCTAssertEqual(results.map(\.longTermMemoryAvailable), [true, false])
    let counts = await transport.requestCounts()
    XCTAssertEqual(counts.readiness, 2)
    XCTAssertEqual(counts.memory, 1)
  }

  func testPreflightPreservesServerRejectedReadinessDetail() async throws {
    let instance = KaibaInstance(
      name: "Rejected",
      endpoint: "https://rejected.example.test",
      authentication: .unauthenticated,
      isDefault: true,
      allowRemoteUnauthenticated: true
    )
    let snapshot = try KaibaExecutionSnapshot(
      bindingIDs: [nil],
      catalog: .init(instances: [instance]),
      environment: [:],
      clientFactory: KaibaClientFactory(transportFactory: { RejectedReadinessTransport() })
    )

    do {
      _ = try await snapshot.preflight(requests: [.init(instanceID: nil)])
      XCTFail("expected readiness failure")
    } catch let error as KaibaExecutionSnapshot.PreflightError {
      XCTAssertEqual(error, .readinessFailed(
        instanceID: instance.id,
        status: .incompatible,
        code: "server_rejected"
      ))
    }
  }
}

private struct SnapshotTransport: KaibaHTTPTransporting {
  func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
    KaibaHTTPResponse(
      statusCode: 200,
      body: Data("{\"data\":{\"kaibaReadiness\":{\"result\":{\"accepted\":true,\"status\":\"ok\"}}}}".utf8)
    )
  }
}

private struct RejectedReadinessTransport: KaibaHTTPTransporting {
  func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
    KaibaHTTPResponse(
      statusCode: 200,
      body: Data("{\"data\":{\"kaibaReadiness\":{\"result\":{\"accepted\":false,\"status\":\"rejected\"}}}}".utf8)
    )
  }
}

private actor RecordingSnapshotTransport: KaibaHTTPTransporting {
  private var readinessCount = 0
  private var memoryCount = 0

  func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
    let document = String(data: request.body, encoding: .utf8) ?? ""
    if document.contains("KaibaLongTermMemoryNotebook") {
      memoryCount += 1
      return .init(statusCode: 200, body: Data("""
      {"data":{"root":{"result":{"accepted":true,"status":"ok","diagnostics":[]},
      "value":{"notebookId":"memory","title":"Memory","readOnly":false,
      "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z",
      "metaJSON":null,"tags":[],"firstNotePreview":null,"noteCount":0,
      "libraryId":null,"ownerUserId":null,"createdBy":null,"updatedBy":null}}}}
      """.utf8))
    }
    readinessCount += 1
    return .init(
      statusCode: 200,
      body: Data("{\"data\":{\"kaibaReadiness\":{\"result\":{\"accepted\":true,\"status\":\"ok\"}}}}".utf8)
    )
  }

  func requestCounts() -> (readiness: Int, memory: Int) {
    (readinessCount, memoryCount)
  }
}
