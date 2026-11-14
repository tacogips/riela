import Foundation
import XCTest
@testable import RielaKaibaSupport

final class KaibaBindingScannerTests: XCTestCase {
  func testFindsOnlyKaibaNodeConfigBindingsInDeterministicOrder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let workflowDirectory = project.appendingPathComponent(".riela/workflows/example", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    let selectedID = "6A65EE12-1381-4DDB-97F4-4C96AF7609F7"
    let workflow = """
    {
      "workflowId": "example",
      "nodes": [
        { "id": "ignore", "addon": { "name": "other/addon", "config": { "kaibaInstanceId": "\(selectedID)" } } },
        { "id": "match", "addon": { "name": "kaiba/note-search", "config": { "kaibaInstanceId": "\(selectedID)" } } }
      ]
    }
    """
    let source = workflowDirectory.appendingPathComponent("workflow.json")
    try Data(workflow.utf8).write(to: source)

    let references = try KaibaBindingScanner().references(
      to: selectedID,
      roots: .init(projectRootURL: project, homeURL: home)
    )

    XCTAssertEqual(references.count, 1)
    XCTAssertEqual(references[0].scope, .project)
    XCTAssertEqual(references[0].workflowId, "example")
    XCTAssertEqual(references[0].nodeId, "match")
    XCTAssertEqual(references[0].bindingOrigin, .definition)
    XCTAssertEqual(references[0].sourcePath, source.path)
  }

  func testFailsClosedForMalformedWorkflowDocument() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    let source = project.appendingPathComponent(".riela/workflows/bad/workflow.json")
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not JSON".utf8).write(to: source)

    XCTAssertThrowsError(
      try KaibaBindingScanner().references(to: "selected", roots: .init(projectRootURL: project, homeURL: root))
    ) { error in
      XCTAssertEqual(error as? KaibaBindingScannerError, .failed)
    }
  }

  func testScansRegisteredExternalWorkflowRoots() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    let external = root.appendingPathComponent("external-workflow", isDirectory: true)
    let appRoot = home.appendingPathComponent(".riela/rielaapp", isDirectory: true)
    let profile = appRoot.appendingPathComponent("profiles/default", isDirectory: true)
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    let state = "{ \"workflowDirectories\": [\"\(external.path)\"] }"
    try Data(state.utf8)
      .write(to: profile.appendingPathComponent("daemon-workflows.json"))
    let selectedID = "2B517799-ECD4-4A0E-9C08-23B30CC2835A"
    let workflow = """
    { "workflowId": "external", "nodes": [
      { "id": "node", "addon": { "name": "kaiba/knowledge-search", "config": { "kaibaInstanceId": "\(selectedID)" } } }
    ] }
    """
    try Data(workflow.utf8).write(to: external.appendingPathComponent("workflow.json"))

    let references = try KaibaBindingScanner().references(
      to: selectedID,
      roots: .init(projectRootURL: project, homeURL: home, appRootURL: appRoot)
    )

    XCTAssertEqual(references.count, 1)
    XCTAssertEqual(references[0].scope, .external)
    XCTAssertEqual(references[0].profile, "default")
    XCTAssertEqual(references[0].workflowId, "external")
  }

  func testScansProjectAndProfileInstancePatches() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    let appRoot = home.appendingPathComponent(".riela/rielaapp", isDirectory: true)
    let profile = appRoot.appendingPathComponent("profiles/default", isDirectory: true)
    let selectedID = "1DE4DDEA-EA4C-4608-9D1F-EDEE362EE245"
    let projectState = project.appendingPathComponent(".riela/instances.json")
    try FileManager.default.createDirectory(at: projectState.deletingLastPathComponent(), withIntermediateDirectories: true)
    let projectJSON = """
    {"instances":[{"identity":"project-instance","workflowId":"project-workflow",
    "configuration":{"nodePatches":{"project-node":{"addon":{"name":"kaiba/note-search",
    "config":{"kaibaInstanceId":"\(selectedID)"}}}}}}]}
    """
    try Data(projectJSON.utf8).write(to: projectState)
    let profileState = profile.appendingPathComponent("daemon-workflows.json")
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    let profileJSON = """
    {"preferences":{"profile-instance":{"identity":"profile-instance",
    "sourceIdentity":"project-workflow:profile-workflow","configuration":{"nodePatches":
    {"profile-node":{"addon":{"name":"kaiba/knowledge-search","config":
    {"kaibaInstanceId":"\(selectedID)"}}}}}}}}
    """
    try Data(profileJSON.utf8).write(to: profileState)

    let references = try KaibaBindingScanner().references(
      to: selectedID,
      roots: .init(projectRootURL: project, homeURL: home, appRootURL: appRoot)
    )

    XCTAssertEqual(references.count, 2)
    XCTAssertEqual(references[0].scope, .project)
    XCTAssertEqual(references[0].workflowInstanceIdentity, "project-instance")
    XCTAssertEqual(references[0].bindingOrigin, .instancePatch)
    XCTAssertEqual(references[1].scope, .profile)
    XCTAssertEqual(references[1].profile, "default")
    XCTAssertEqual(references[1].workflowId, "profile-workflow")
    XCTAssertEqual(references[1].workflowInstanceIdentity, "profile-instance")
    XCTAssertEqual(references[1].bindingOrigin, .instancePatch)
  }

  func testFailsClosedForDuplicateKeysInScannedState() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    let source = project.appendingPathComponent(".riela/workflows/bad/workflow.json")
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(
      #"{"workflowId":"one","workflowId":"two","nodes":[]}"#.utf8
    ).write(to: source)

    XCTAssertThrowsError(
      try KaibaBindingScanner().references(to: "selected", roots: .init(projectRootURL: project, homeURL: root))
    ) { error in
      XCTAssertEqual(error as? KaibaBindingScannerError, .failed)
    }
  }

  func testFailsClosedWhenSourceSetChangesAfterInitialSnapshot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    let original = project.appendingPathComponent(".riela/workflows/original/workflow.json")
    let added = project.appendingPathComponent(".riela/workflows/added/workflow.json")
    try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: added.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"workflowId":"original","nodes":[]}"#.utf8).write(to: original)
    let addedDocument = Data(#"{"workflowId":"added","nodes":[]}"#.utf8)
    let scanner = KaibaBindingScanner(afterInitialSourceSnapshot: {
      precondition(FileManager.default.createFile(atPath: added.path, contents: addedDocument))
      do {
        try FileManager.default.removeItem(at: original)
      } catch {
        preconditionFailure("test source removal failed")
      }
    })

    XCTAssertThrowsError(
      try scanner.references(to: "selected", roots: .init(projectRootURL: project, homeURL: root))
    ) { error in
      XCTAssertEqual(error as? KaibaBindingScannerError, .failed)
    }
  }

  func testProjectsReferencesFromInitialSnapshotAcrossRestoredSourceChange() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    let source = project.appendingPathComponent(".riela/workflows/example/workflow.json")
    let selectedID = "0182CBE3-43A7-441E-986F-227A5484432B"
    let original = Data(
      """
      {"workflowId":"example","nodes":[{"id":"node","addon":{"name":"kaiba/note-search","config":{"kaibaInstanceId":"\(selectedID)"}}}]}
      """.utf8
    )
    let transient = Data(#"{"workflowId":"example","nodes":[]}"#.utf8)
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try original.write(to: source)
    let scanner = KaibaBindingScanner(
      afterInitialSourceSnapshot: {
        do {
          try transient.write(to: source)
        } catch {
          preconditionFailure("test transient source mutation failed")
        }
      },
      beforeFinalSourceSnapshot: {
        do {
          try original.write(to: source)
        } catch {
          preconditionFailure("test source restoration failed")
        }
      }
    )

    let references = try scanner.references(
      to: selectedID,
      roots: .init(projectRootURL: project, homeURL: root)
    )

    XCTAssertEqual(references.count, 1)
    XCTAssertEqual(references[0].kaibaInstanceId, selectedID)
  }

  func testDeduplicatesCanonicalProjectAndUserRoots() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent(".riela/workflows/example/workflow.json")
    let selectedID = "FCE2B06B-7A47-49A4-BEF2-6187B3998DB6"
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(
      """
      {"workflowId":"example","nodes":[{"id":"node","addon":{"name":"kaiba/note-search","config":{"kaibaInstanceId":"\(selectedID)"}}}]}
      """.utf8
    ).write(to: source)

    let references = try KaibaBindingScanner().references(
      to: selectedID,
      roots: .init(projectRootURL: root, homeURL: root)
    )

    XCTAssertEqual(references.count, 1)
    XCTAssertEqual(references[0].scope, .project)
  }

  func testFailsClosedForProjectAndUserInstanceFileSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let escapedState = FileManager.default.temporaryDirectory
      .appendingPathComponent("escaped-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: escapedState) }
    try Data(#"{"instances":[]}"#.utf8).write(to: escapedState)

    for scanRoot in [project, home] {
      let source = scanRoot.appendingPathComponent(".riela/instances.json")
      try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(at: source, withDestinationURL: escapedState)
      XCTAssertThrowsError(
        try KaibaBindingScanner().references(
          to: "selected",
          roots: .init(projectRootURL: project, homeURL: home)
        )
      ) { error in
        XCTAssertEqual(error as? KaibaBindingScannerError, .failed)
      }
      try FileManager.default.removeItem(at: source)
    }
  }
}
