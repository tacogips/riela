import Foundation
import RielaAppSupport
import RielaCore
import XCTest

final class RielaAppProfileWorkflowSourcesTests: XCTestCase {
  func testDiscoveryResolutionAndSessionPath() throws {
    let root = URL(fileURLWithPath: "/tmp/rac-" + String(UUID().uuidString.prefix(8)).lowercased(), isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let appRoot = root.appendingPathComponent("app")
    let profile = RielaAppProfileName("p")
    let state = RielaAppDaemonWorkflowState(workflowStorageDirectory: root.appendingPathComponent("storage").path)
    let workflow = RielaAppProfileStore.workflowRootURL(
      appRootURL: appRoot, profileName: profile, storageDirectory: state.workflowStorageDirectory
    ).appendingPathComponent("fixture")
    try FileManager.default.createDirectory(at: workflow, withIntermediateDirectories: true)
    try """
    {"workflowId":"fixture","description":"","steps":[],"nodes":[]}
    """.write(to: workflow.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    let sources = RielaAppProfileWorkflowSources.discover(
      appRootURL: appRoot, profileName: profile, state: state, projectRoot: nil
    )
    let candidate = try XCTUnwrap(sources.first { $0.workflowId == "fixture" })
    XCTAssertEqual(RielaAppProfileWorkflowSources.resolveSource(
      sourceIdentity: candidate.id, appRootURL: appRoot, profileName: profile, state: state
    )?.id, candidate.id)
    XCTAssertEqual(RielaAppProfileWorkflowSources.resolveSource(
      sourceIdentity: "selected-workflow:" + workflow.path, appRootURL: appRoot, profileName: profile, state: state
    )?.workflowDirectory, workflow.path)
    XCTAssertNil(RielaAppProfileWorkflowSources.resolveSource(
      sourceIdentity: "unknown", appRootURL: appRoot, profileName: profile, state: state
    ))
    XCTAssertEqual(RielaAppProfileStore.sessionStoreRootURL(
      homeDirectory: root.appendingPathComponent("home"), profileName: profile
    ).path, root.appendingPathComponent("home/.riela/profiles/p/sessions").path)
  }

  func testEmptyExecutionsAndAbsentDetail() {
    let root = URL(fileURLWithPath: "/tmp/rac-" + String(UUID().uuidString.prefix(8)).lowercased(), isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let local = RielaAppInstanceExecutionsProjection.list(
      identity: "fixture", workflowDirectory: root.path, sessionStoreRoot: root.appendingPathComponent("sessions").path,
      revision: nil
    )
    XCTAssertEqual(local["items"], .array([]))
    XCTAssertEqual(local["truncated"], .bool(false))
    XCTAssertNil(local["revision"])
    let remote = RielaAppInstanceExecutionsProjection.list(
      identity: "fixture", workflowDirectory: root.path, sessionStoreRoot: root.appendingPathComponent("sessions").path,
      revision: 3
    )
    XCTAssertEqual(remote["revision"], .number(3))
    XCTAssertNil(RielaAppInstanceExecutionsProjection.detailStatus(
      workflowDirectory: root.path, sessionStoreRoot: root.appendingPathComponent("sessions").path, sessionId: "absent"
    ))
  }
}
