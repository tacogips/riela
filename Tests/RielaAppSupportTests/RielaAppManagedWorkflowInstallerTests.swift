#if os(macOS)
import RielaAddons
import XCTest
@testable import RielaAppSupport

final class RielaAppManagedWorkflowInstallerTests: XCTestCase {
  func testSupportedPackageArchiveExtensionsMatchAppImportPickerInputs() {
    XCTAssertEqual(RielaAppManagedPackageInstaller.supportedPackageArchiveExtensions, ["rielapkg", "zip"])
  }

  func testUnsupportedPackageSourceDescriptionMatchesImportPickerInputs() {
    let error = RielaAppManagedWorkflowInstallError.unsupportedPackageSource("/tmp/not-a-package")

    XCTAssertEqual(
      error.localizedDescription,
      "Selected source is not a workflow folder, package folder, .rielapkg, or .zip package: /tmp/not-a-package"
    )
  }

  func testWorkflowInstallerReportsExistingWorkflowReplacement() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-app-workflow-replace-\(UUID().uuidString)", isDirectory: true)
    let source = root.appendingPathComponent("source/workflow", isDirectory: true)
    let destination = root.appendingPathComponent("profile/workflows", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let workflowURL = source.appendingPathComponent("workflow.json")
    let installer = RielaAppManagedWorkflowInstaller(workflowRoot: destination)

    try #"{"workflowId":"replace-workflow","marker":"v1"}"#
      .write(to: workflowURL, atomically: true, encoding: .utf8)
    let firstInstall = try installer.installWorkflowDirectoryResult(source)
    XCTAssertFalse(firstInstall.replacedExisting)

    try #"{"workflowId":"replace-workflow","marker":"v2"}"#
      .write(to: workflowURL, atomically: true, encoding: .utf8)
    let secondInstall = try installer.installWorkflowDirectoryResult(source)

    XCTAssertTrue(secondInstall.replacedExisting)
    XCTAssertEqual(
      try String(contentsOf: secondInstall.installedURL.appendingPathComponent("workflow.json"), encoding: .utf8),
      #"{"workflowId":"replace-workflow","marker":"v2"}"#
    )
  }

  func testImportSourceClassifierPrefersPackageManifestOverWorkflowDirectory() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-app-source-classifier-\(UUID().uuidString)", isDirectory: true)
    let source = root.appendingPathComponent("source/package", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try "{}".write(to: source.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try "{}".write(to: source.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    XCTAssertEqual(RielaAppImportSourceClassifier.kind(for: source), .packageSource)
    XCTAssertEqual(RielaAppImportSourceClassifier.kind(for: source.appendingPathComponent("demo.rielapkg")), .packageSource)
  }

  func testPackageInstallerReportsExistingPackageReplacement() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-app-package-replace-\(UUID().uuidString)", isDirectory: true)
    let source = root.appendingPathComponent("source/package", isDirectory: true)
    let destination = root.appendingPathComponent("profile/packages", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try writePackageSource(
      source,
      packageName: "replace-package",
      workflowId: "replace-package-workflow",
      marker: "v1"
    )
    let installer = RielaAppManagedPackageInstaller(packageRoot: destination)
    let firstInstall = try installer.installPackageSourceResult(source)
    XCTAssertFalse(firstInstall.replacedExisting)

    try writePackageSource(
      source,
      packageName: "replace-package",
      workflowId: "replace-package-workflow",
      marker: "v2"
    )
    let secondInstall = try installer.installPackageSourceResult(source)

    XCTAssertTrue(secondInstall.replacedExisting)
    XCTAssertEqual(
      try String(contentsOf: secondInstall.installedURL.appendingPathComponent("workflow.json"), encoding: .utf8),
      #"{"workflowId":"replace-package-workflow","marker":"v2"}"#
    )
  }

  func testPackageInstallerRejectsChecksumMismatch() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-app-installer-checksum-\(UUID().uuidString)", isDirectory: true)
    let source = root.appendingPathComponent("source/package", isDirectory: true)
    let destination = root.appendingPathComponent("profile/packages", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try """
    {"workflowId":"checksum-workflow","steps":[],"nodes":[]}
    """.write(to: source.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    let checksum = try WorkflowPackageChecksum.md5(packageRoot: source)
    try """
    {
      "name": "checksum-package",
      "version": "1.0.0",
      "description": "Checksum package",
      "tags": ["profile"],
      "registry": "local",
      "checksum": "\(checksum)",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: source.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
    try """
    {"workflowId":"checksum-workflow","steps":[{"id":"changed"}],"nodes":[]}
    """.write(to: source.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    let installer = RielaAppManagedPackageInstaller(packageRoot: destination)

    XCTAssertThrowsError(try installer.installPackageSource(source)) { error in
      guard case let .invalidPackageManifest(_, issues) = error as? RielaAppManagedWorkflowInstallError else {
        return XCTFail("expected invalidPackageManifest, got \(error)")
      }
      XCTAssertTrue(issues.contains { $0.contains("checksum does not match package contents") })
    }
  }

  private func writePackageSource(
    _ source: URL,
    packageName: String,
    workflowId: String,
    marker: String
  ) throws {
    if FileManager.default.fileExists(atPath: source.path) {
      try FileManager.default.removeItem(at: source)
    }
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try #"{"workflowId":"\#(workflowId)","marker":"\#(marker)"}"#
      .write(to: source.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    let checksum = try WorkflowPackageChecksum.md5(packageRoot: source)
    try """
    {
      "name": "\(packageName)",
      "version": "1.0.0",
      "description": "Replacement package",
      "tags": ["profile"],
      "registry": "local",
      "checksum": "\(checksum)",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: source.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
  }
}
#endif
