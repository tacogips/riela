import XCTest
@testable import RielaCLI
@testable import RielaCore
@testable import RielaWorkflowRegistry

final class WorkflowActivationTests: XCTestCase {
  func testActivationStateDefaultsActive() throws {
    let origin = WorkflowOriginIdentity(scope: .user, sourceKind: .workflow, provenance: .mutable, name: "demo", workflowId: "demo", canonicalLocator: "/tmp/demo")
    XCTAssertTrue(origin.originId.hasPrefix("wfo_"))
    XCTAssertEqual(origin.originId.count, 68)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("riela-activation-default-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let state = try CLIRuntimeEnvironment.$overrides.withValue(["HOME": root.path]) {
      try WorkflowActivationStore().state(for: origin)
    }
    XCTAssertEqual(state, .active)
  }

  func testActivationMutationFailsClosedWhenPinnedStateRootIsReplaced() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("riela-activation-root-swap-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let stateRoot = root.appendingPathComponent(".riela/workflow-state", isDirectory: true)
    let displacedRoot = root.appendingPathComponent(".riela/workflow-state-displaced", isDirectory: true)
    let decoy = Data(#"{"schemaVersion":1,"deactivated":{}}"#.utf8)
    let origin = WorkflowOriginIdentity(scope: .user, sourceKind: .workflow, provenance: .mutable, name: "root-swap", workflowId: "root-swap", canonicalLocator: "/tmp/root-swap")
    let store = WorkflowActivationStore(hooks: WorkflowActivationStoreHooks(afterStateRootPin: {
      try FileManager.default.moveItem(at: stateRoot, to: displacedRoot)
      try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: false)
      try decoy.write(to: stateRoot.appendingPathComponent("activation.json"))
    }))
    XCTAssertThrowsError(try CLIRuntimeEnvironment.$overrides.withValue(["HOME": root.path]) { try store.set(.deactivated, for: origin) })
    XCTAssertEqual(try Data(contentsOf: stateRoot.appendingPathComponent("activation.json")), decoy)
    XCTAssertFalse(FileManager.default.fileExists(atPath: displacedRoot.appendingPathComponent("activation.json").path))
  }
}

final class WorkflowConsolidationTests: XCTestCase {
  func testRetireModesAreClosedTypedValues() { XCTAssertEqual(WorkflowRetireMode.allCases, [.deactivate, .delete]) }

  func testConsolidationJournalWriteCannotFollowReplacedStateRoot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("riela-consolidation-root-swap-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let stateRoot = root.appendingPathComponent(".riela/workflow-state", isDirectory: true)
    let displacedRoot = root.appendingPathComponent(".riela/workflow-state-displaced", isDirectory: true)
    let decoy = Data("do-not-replace".utf8)
    let journal = WorkflowConsolidationJournal(
      schemaVersion: 1,
      transactionId: UUID().uuidString.lowercased(),
      phase: .prepared,
      sources: [],
      replacementWorkflowId: "replacement",
      replacementDigest: "digest",
      retireMode: .deactivate,
      activateReplacement: true
    )
    XCTAssertThrowsError(try CLIRuntimeEnvironment.$overrides.withValue(["HOME": root.path]) {
      try WorkflowActivationStore().withCoordinatorLock {
        try FileManager.default.moveItem(at: stateRoot, to: displacedRoot)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: false)
        try decoy.write(to: stateRoot.appendingPathComponent("consolidation.json"))
        try WorkflowRegistryCoordinator().write(journal)
      }
    })
    XCTAssertEqual(try Data(contentsOf: stateRoot.appendingPathComponent("consolidation.json")), decoy)
    let displacedJournal = displacedRoot.appendingPathComponent("consolidation.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: displacedJournal.path))
    XCTAssertEqual(try JSONDecoder().decode(WorkflowConsolidationJournal.self, from: Data(contentsOf: displacedJournal)), journal)
  }
}
