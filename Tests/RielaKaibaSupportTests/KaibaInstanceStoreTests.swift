import Foundation
import XCTest
@testable import RielaKaibaSupport

final class KaibaInstanceStoreTests: XCTestCase {
  func testFirstInstanceBecomesValidatedDefaultWithoutPersistingToken() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let instance = KaibaInstance(
      name: "Local",
      endpoint: "https://localhost:8080/graphql",
      authentication: .bearer(environmentVariable: "KAIBA_TOKEN"),
      isDefault: true
    )
    let store = KaibaInstanceStore(homeURL: root)
    try store.save(KaibaInstanceCatalog(instances: [instance]))
    let loaded = try store.load()
    XCTAssertEqual(loaded.instances.first?.endpoint, "https://localhost:8080/graphql")
    XCTAssertFalse(try String(contentsOf: store.fileURL).contains("secret-token"))
  }

  func testReloadsISO8601ReadinessAndMutationDoesNotPersistTokenValue() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let sentinel = "never-persist-this-token"
    let store = KaibaInstanceStore(homeURL: root)
    let instance = KaibaInstance(
      name: "Remote",
      endpoint: "https://example.test",
      authentication: .bearer(environmentVariable: "KAIBA_TOKEN"),
      isDefault: true,
      lastTest: .init(status: .ready, attemptedAt: Date(timeIntervalSince1970: 1_700_000_000))
    )
    let client = try KaibaClientFactory().makeClient(
      instance: instance,
      environment: ["KAIBA_TOKEN": sentinel]
    )
    try store.save(.init(instances: [instance]))
    XCTAssertEqual(try store.load().instances.first?.lastTest.status, .ready)
    _ = try store.mutate { $0 }
    XCTAssertFalse(try String(contentsOf: store.fileURL).contains(sentinel))
    XCTAssertFalse(String(reflecting: client).contains(sentinel))
  }

  func testRejectsDisabledDefaultAndCustomEndpointPath() throws {
    let disabledDefault = KaibaInstance(name: "Local", endpoint: "https://localhost/graphql", authentication: .unauthenticated, enabled: false, isDefault: true)
    XCTAssertThrowsError(try KaibaInstanceValidation.validated(.init(instances: [disabledDefault])))
    let customPath = KaibaInstance(name: "Local", endpoint: "https://localhost/private", authentication: .unauthenticated, isDefault: true)
    XCTAssertThrowsError(try KaibaInstanceValidation.validated(.init(instances: [customPath])))
  }

  func testDoesNotTreatDNSNameBeginningWithLoopbackPrefixAsLoopback() {
    let remoteHTTP = KaibaInstance(
      name: "Remote",
      endpoint: "http://127.example.test",
      authentication: .unauthenticated,
      isDefault: true
    )
    XCTAssertThrowsError(try KaibaInstanceValidation.validated(.init(instances: [remoteHTTP])))
  }

  func testRemoteHTTPAndUnauthenticatedInstancesRequireSeparateExplicitOptIns() throws {
    let remoteHTTP = KaibaInstance(
      name: "Remote HTTP",
      endpoint: "http://kaiba.example.test/graphql",
      authentication: .bearer(environmentVariable: "KAIBA_TOKEN"),
      isDefault: true
    )
    XCTAssertThrowsError(try KaibaInstanceValidation.validated(.init(instances: [remoteHTTP])))

    var optedInHTTP = remoteHTTP
    optedInHTTP.allowInsecureHTTP = true
    XCTAssertNoThrow(try KaibaInstanceValidation.validated(.init(instances: [optedInHTTP])))

    let remoteUnauthenticated = KaibaInstance(
      name: "Remote unauthenticated",
      endpoint: "https://kaiba.example.test/graphql",
      authentication: .unauthenticated,
      isDefault: true
    )
    XCTAssertThrowsError(try KaibaInstanceValidation.validated(.init(instances: [remoteUnauthenticated])))

    var optedInUnauthenticated = remoteUnauthenticated
    optedInUnauthenticated.allowRemoteUnauthenticated = true
    XCTAssertNoThrow(try KaibaInstanceValidation.validated(.init(instances: [optedInUnauthenticated])))
  }

  func testRejectsDuplicateJSONKeysBeforeDecoding() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = KaibaInstanceStore(homeURL: root)
    try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let duplicateCatalog = #"{"schemaVersion":1,"schemaVersion":1,"instances":[]}"#
    try Data(duplicateCatalog.utf8).write(to: store.fileURL)
    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(error as? KaibaInstanceStoreError, .invalidStore)
    }
  }

  func testSharedValidationNormalizesNamesAndRejectsInvalidPersistedNames() throws {
    let instance = KaibaInstance(
      name: "  Cafe\u{301} ",
      endpoint: "https://localhost/graphql",
      authentication: .unauthenticated,
      isDefault: true
    )
    XCTAssertEqual(try KaibaInstanceValidation.validated(.init(instances: [instance])).instances[0].name, "Café")

    let invalid = KaibaInstance(
      name: String(repeating: "a", count: 81),
      endpoint: "https://localhost/graphql",
      authentication: .unauthenticated,
      isDefault: true
    )
    XCTAssertThrowsError(try KaibaInstanceValidation.validated(.init(instances: [invalid])))
  }

  func testCaseFoldedNameKeysDoNotEraseDiacritics() throws {
    let cafe = KaibaInstance(
      name: "Cafe",
      endpoint: "https://localhost/graphql",
      authentication: .unauthenticated,
      isDefault: true
    )
    let accented = KaibaInstance(
      name: "Café",
      endpoint: "https://localhost/graphql",
      authentication: .unauthenticated
    )
    XCTAssertNoThrow(try KaibaInstanceValidation.validated(.init(instances: [cafe, accented])))
  }

  func testLoadClassifiesInvalidPersistedInstanceAsInvalidStore() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = KaibaInstanceStore(homeURL: root)
    try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let catalog = """
    {
      "schemaVersion": 1,
      "instances": [{
        "id": "00000000-0000-0000-0000-000000000000",
        "name": "bad\\nname",
        "endpoint": "https://localhost/graphql",
        "authentication": { "mode": "unauthenticated" },
        "enabled": true,
        "isDefault": true,
        "allowInsecureHTTP": false,
        "allowRemoteUnauthenticated": false,
        "lastTest": { "status": "untested" }
      }]
    }
    """
    try Data(catalog.utf8).write(to: store.fileURL)
    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(error as? KaibaInstanceStoreError, .invalidStore)
    }
  }

  func testRowMutationRejectsAStaleSnapshot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = KaibaInstanceStore(homeURL: root)
    let instance = KaibaInstance(name: "Local", endpoint: "https://localhost/graphql", authentication: .unauthenticated, isDefault: true)
    try store.save(.init(instances: [instance]))
    let snapshot = try XCTUnwrap(store.load().instances.first)
    _ = try store.mutateInstance(id: instance.id, expected: snapshot) { current in
      var updated = current
      updated.endpoint = "https://localhost:8443/graphql"
      return updated
    }
    XCTAssertThrowsError(try store.mutateInstance(id: instance.id, expected: snapshot) { $0 }) { error in
      XCTAssertEqual(error as? KaibaInstanceStoreError, .changedInstance)
    }
  }

  func testLifecycleInvalidatesChangedTransportAndRecordsDisabledState() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let original = KaibaInstance(
      name: "Local",
      endpoint: "https://localhost/graphql",
      authentication: .unauthenticated,
      isDefault: true,
      lastTest: .init(status: .ready, attemptedAt: date)
    )
    var changedEndpoint = original
    changedEndpoint.endpoint = "https://localhost:8443/graphql"
    XCTAssertEqual(
      try KaibaInstanceLifecycle.applyingUpdate(from: original, to: changedEndpoint, at: date).lastTest,
      .init()
    )

    var disabled = original
    disabled.enabled = false
    XCTAssertEqual(
      try KaibaInstanceLifecycle.applyingUpdate(from: original, to: disabled, at: date).lastTest,
      .init(status: .disabled, code: "disabled_kaiba_instance", attemptedAt: date)
    )

    var equivalentRoot = original
    equivalentRoot.endpoint = "https://localhost"
    let preserved = try KaibaInstanceLifecycle.applyingUpdate(from: original, to: equivalentRoot, at: date)
    XCTAssertEqual(preserved.endpoint, original.endpoint)
    XCTAssertEqual(preserved.lastTest, original.lastTest)
  }
}
