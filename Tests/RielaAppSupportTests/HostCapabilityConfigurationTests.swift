import Foundation
import RielaCore
import XCTest
@testable import RielaAppSupport

final class HostCapabilityConfigurationTests: XCTestCase {
  func testProfileBackendDeclarationsRoundTripAndLegacyDefaultsEmpty() throws {
    let state = RielaAppDaemonWorkflowState(backends: [
      NodeExecutionBackend.codexAgent.rawValue: BackendCapabilityDeclaration(
        enabled: true,
        models: ["gpt"]
      )
    ])
    let decoded = try JSONDecoder().decode(
      RielaAppDaemonWorkflowState.self,
      from: JSONEncoder().encode(state)
    )
    XCTAssertEqual(decoded.backends, state.backends)
    let legacy = try JSONDecoder().decode(RielaAppDaemonWorkflowState.self, from: Data(#"{"version":1}"#.utf8))
    XCTAssertEqual(legacy.backends, [:])
  }

  func testReadOnlyCorruptProfileNeverQuarantinesOrWrites() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let stateURL = root.appendingPathComponent("daemon-workflows.json")
    try Data("not-json".utf8).write(to: stateURL)
    let store = RielaAppDaemonWorkflowStore(stateURL: stateURL)
    let result = store.loadReadOnlyResult()
    XCTAssertNil(result.state)
    XCTAssertNotNil(result.error)
    XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: RielaAppDaemonWorkflowStore.corruptStateQuarantineURL(for: stateURL).path))
  }
}
