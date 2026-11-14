import Foundation
import RielaAddons
import XCTest
@testable import RielaCLI

extension WorkflowCommandTests {
  func testPackageInitCreatesManifestUsedByPackAndValidate() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-init-package-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: packageSource, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/workflow.json"),
      to: packageSource.appendingPathComponent("workflow.json")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/nodes"),
      to: packageSource.appendingPathComponent("nodes")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/prompts"),
      to: packageSource.appendingPathComponent("prompts")
    )

    let app = RielaCLIApplication()
    let initialize = await app.run([
      "package", "init", packageSource.path,
      "--package-name", "init-demo",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertEqual(initialize.exitCode, .success, initialize.stderr)
    let initialized = try decodeJSON(WorkflowPackageCommandResult.self, from: initialize.stdout)
    let manifestURL = packageSource.appendingPathComponent("riela-package.json")
    XCTAssertEqual(initialized.destinationDirectory, manifestURL.path)
    XCTAssertEqual(initialized.packages.first?.name, "init-demo")
    XCTAssertEqual(initialized.packages.first?.valid, true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
    let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
    XCTAssertTrue(manifestText.contains("\n  \"name\" : \"init-demo\""), manifestText)
    XCTAssertTrue(manifestText.contains("\n  \"workflowDirectory\" : \".\""), manifestText)
    XCTAssertTrue(manifestText.hasSuffix("\n"), manifestText)
    let manifestObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(manifestText.utf8)) as? [String: Any])
    let checksum = try XCTUnwrap(manifestObject["checksum"] as? String)
    XCTAssertNotEqual(checksum, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    XCTAssertNotNil(checksum.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression), checksum)

    let pack = await app.run([
      "package", "pack", packageSource.path,
      "--destination", tempDir.appendingPathComponent("init-demo.rielapkg").path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(pack.exitCode, .success, pack.stderr)
    let packed = try decodeJSON(WorkflowPackageCommandResult.self, from: pack.stdout)
    let archiveURL = try XCTUnwrap(packed.destinationDirectory)

    let validate = await app.run([
      "package", "validate", archiveURL,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .success, validate.stdout)
    let validated = try decodeJSON(WorkflowPackageCommandResult.self, from: validate.stdout)
    XCTAssertEqual(validated.packages.first?.name, "init-demo")
    XCTAssertEqual(validated.packages.first?.valid, true)

    let relativePackageSource = tempDir.appendingPathComponent("relative-package-source", isDirectory: true)
    try FileManager.default.createDirectory(at: relativePackageSource, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: packageSource.appendingPathComponent("workflow.json"),
      to: relativePackageSource.appendingPathComponent("workflow.json")
    )
    try FileManager.default.copyItem(
      at: packageSource.appendingPathComponent("nodes"),
      to: relativePackageSource.appendingPathComponent("nodes")
    )
    try FileManager.default.copyItem(
      at: packageSource.appendingPathComponent("prompts"),
      to: relativePackageSource.appendingPathComponent("prompts")
    )
    let relativeInitialize = await app.run([
      "package", "init", "relative-package-source",
      "--package-name", "relative-init-demo",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertEqual(relativeInitialize.exitCode, .success, relativeInitialize.stderr)
    let relativeInitialized = try decodeJSON(WorkflowPackageCommandResult.self, from: relativeInitialize.stdout)
    XCTAssertEqual(
      relativeInitialized.destinationDirectory,
      relativePackageSource.appendingPathComponent("riela-package.json").path
    )
    XCTAssertEqual(relativeInitialized.packages.first?.packageDirectory, relativePackageSource.path)
  }

  func testPackageInitChecksumAndArchiveIncludeHiddenEventSources() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-init-hidden-events-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    let eventSource = packageSource.appendingPathComponent(".riela-events/sources/webhook.json")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: packageSource, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/workflow.json"),
      to: packageSource.appendingPathComponent("workflow.json")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/nodes"),
      to: packageSource.appendingPathComponent("nodes")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/prompts"),
      to: packageSource.appendingPathComponent("prompts")
    )
    try FileManager.default.createDirectory(at: eventSource.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"id":"webhook-a","kind":"webhook","path":"/events/a"}"#
      .write(to: eventSource, atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    let initialize = await app.run([
      "package", "init", packageSource.path,
      "--package-name", "hidden-events-demo",
      "--working-dir", tempDir.path
    ])
    XCTAssertEqual(initialize.exitCode, .success, initialize.stderr)
    let initialChecksum = try checksum(in: packageSource.appendingPathComponent("riela-package.json"))

    try "finder metadata".write(
      to: packageSource.appendingPathComponent(".DS_Store"),
      atomically: true,
      encoding: .utf8
    )
    let gitHead = packageSource.appendingPathComponent(".git/HEAD")
    try FileManager.default.createDirectory(at: gitHead.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "ref: refs/heads/main".write(to: gitHead, atomically: true, encoding: .utf8)
    let withLocalMetadata = await app.run([
      "package", "init", packageSource.path,
      "--package-name", "hidden-events-demo",
      "--overwrite",
      "--working-dir", tempDir.path
    ])
    XCTAssertEqual(withLocalMetadata.exitCode, .success, withLocalMetadata.stderr)
    XCTAssertEqual(initialChecksum, try checksum(in: packageSource.appendingPathComponent("riela-package.json")))

    try #"{"id":"webhook-a","kind":"webhook","path":"/events/b"}"#
      .write(to: eventSource, atomically: true, encoding: .utf8)
    let reinitialize = await app.run([
      "package", "init", packageSource.path,
      "--package-name", "hidden-events-demo",
      "--overwrite",
      "--working-dir", tempDir.path
    ])
    XCTAssertEqual(reinitialize.exitCode, .success, reinitialize.stderr)
    let updatedChecksum = try checksum(in: packageSource.appendingPathComponent("riela-package.json"))
    XCTAssertNotEqual(initialChecksum, updatedChecksum)

    let archiveURL = tempDir.appendingPathComponent("hidden-events-demo.rielapkg")
    let pack = await app.run([
      "package", "pack", packageSource.path,
      "--destination", archiveURL.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(pack.exitCode, .success, pack.stderr)

    let extractedRoot = try WorkflowPackageArchiveManager().extractArchive(
      archiveURL,
      to: tempDir.appendingPathComponent("extracted", isDirectory: true)
    )
    let extractedEventSource = extractedRoot.appendingPathComponent(".riela-events/sources/webhook.json")
    XCTAssertEqual(try String(contentsOf: extractedEventSource, encoding: .utf8), #"{"id":"webhook-a","kind":"webhook","path":"/events/b"}"#)
  }

  func testPackageValidateRejectsChecksumMismatch() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-checksum-mismatch-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: packageSource, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/workflow.json"),
      to: packageSource.appendingPathComponent("workflow.json")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/nodes"),
      to: packageSource.appendingPathComponent("nodes")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/prompts"),
      to: packageSource.appendingPathComponent("prompts")
    )

    let app = RielaCLIApplication()
    let initialize = await app.run([
      "package", "init", packageSource.path,
      "--package-name", "checksum-mismatch-demo",
      "--working-dir", tempDir.path
    ])
    XCTAssertEqual(initialize.exitCode, .success, initialize.stderr)

    try "\nchanged after package init\n".write(
      to: packageSource.appendingPathComponent("prompts/main-worker.md"),
      atomically: true,
      encoding: .utf8
    )
    let validate = await app.run([
      "package", "validate", packageSource.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertEqual(validate.exitCode, .failure, validate.stdout + validate.stderr)
    let result = try decodeJSON(WorkflowPackageCommandResult.self, from: validate.stdout)
    XCTAssertEqual(result.packages.first?.valid, false)
    XCTAssertEqual(result.packages.first?.issues.first?.code, "CHECKSUM_MISMATCH")
    XCTAssertTrue(result.packages.first?.issues.first?.message.contains("checksum does not match") == true)
    XCTAssertTrue(result.packages.first?.issues.first?.message.contains("riela package init <package-dir> --overwrite") == true)
  }

  func testPackageInitReportsInvalidWorkflowDiagnostics() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-init-invalid-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: packageSource, withIntermediateDirectories: true)
    try """
    {"workflowId":"bad","nodes":[{"id":"start","type":"worker","prompt":"Say hello"}]}
    """.write(to: packageSource.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    let initialize = await app.run([
      "package", "init", packageSource.path,
      "--package-name", "invalid-demo",
      "--working-dir", tempDir.path
    ])

    XCTAssertEqual(initialize.exitCode, .failure)
    XCTAssertTrue(initialize.stderr.contains("package init workflow validation failed"), initialize.stderr)
    XCTAssertTrue(initialize.stderr.contains("workflow.defaults: must be an object"), initialize.stderr)
    XCTAssertTrue(
      initialize.stderr.contains("Hint: workflow.json nodes must reference nodeFile"),
      initialize.stderr
    )
    XCTAssertTrue(initialize.stderr.contains("Hint: start from examples/worker-only-single-step"), initialize.stderr)
    XCTAssertFalse(initialize.stderr.contains("invalidWorkflow("), initialize.stderr)
  }

  func testPackageInitReportsWorkflowDirectoryMustStayInsidePackage() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-init-path-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    let outsideWorkflow = tempDir.appendingPathComponent("outside-workflow", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: packageSource, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outsideWorkflow, withIntermediateDirectories: true)

    let app = RielaCLIApplication()
    let parentPath = await app.run([
      "package", "init", packageSource.path,
      "--workflow-definition-dir", "../outside-workflow",
      "--package-name", "path-demo",
      "--working-dir", tempDir.path
    ])
    let absolutePath = await app.run([
      "package", "init", packageSource.path,
      "--workflow-definition-dir", outsideWorkflow.path,
      "--package-name", "path-demo",
      "--working-dir", tempDir.path
    ])

    for result in [parentPath, absolutePath] {
      XCTAssertEqual(result.exitCode, .failure)
      XCTAssertTrue(result.stderr.contains("--workflow-definition-dir must stay inside the package"), result.stderr)
      XCTAssertTrue(result.stderr.contains("use a relative path without '..'"), result.stderr)
    }
  }

  func testPackagePackDefaultsArchiveNextToPackageDirectory() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-pack-default-destination-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try makeArchivePackageSource(root: root, packageSource: packageSource, packageName: "default-destination-demo")

    let app = RielaCLIApplication()
    let pack = await app.run([
      "package", "pack", packageSource.path,
      "--working-dir", root,
      "--output", "json"
    ])

    XCTAssertEqual(pack.exitCode, .success, pack.stderr)
    let packed = try decodeJSON(WorkflowPackageCommandResult.self, from: pack.stdout)
    let expectedArchiveURL = tempDir.appendingPathComponent("default-destination-demo.rielapkg")
    XCTAssertEqual(packed.destinationDirectory, expectedArchiveURL.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: expectedArchiveURL.path))

    try FileManager.default.createDirectory(
      at: tempDir.appendingPathComponent("archives", isDirectory: true),
      withIntermediateDirectories: true
    )
    let relativeDestination = await app.run([
      "package", "pack", "package-source",
      "--destination", "archives/relative-destination-demo.rielapkg",
      "--overwrite",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertEqual(relativeDestination.exitCode, .success, relativeDestination.stderr)
    let relativePacked = try decodeJSON(WorkflowPackageCommandResult.self, from: relativeDestination.stdout)
    let expectedRelativeArchiveURL = tempDir.appendingPathComponent("archives/relative-destination-demo.rielapkg")
    XCTAssertEqual(relativePacked.destinationDirectory, expectedRelativeArchiveURL.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: expectedRelativeArchiveURL.path))
  }

  func testPackageArchiveCommandsDefaultToHumanReadableText() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela cli package text \(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package source", isDirectory: true)
    let quotedPackageSource = "'\(packageSource.path)'"
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: packageSource, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/workflow.json"),
      to: packageSource.appendingPathComponent("workflow.json")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/nodes"),
      to: packageSource.appendingPathComponent("nodes")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/prompts"),
      to: packageSource.appendingPathComponent("prompts")
    )

    let app = RielaCLIApplication()
    let initialize = await app.run([
      "package", "init", packageSource.path,
      "--package-name", "text-demo",
      "--working-dir", tempDir.path
    ])
    XCTAssertEqual(initialize.exitCode, .success, initialize.stderr)
    XCTAssertTrue(initialize.stdout.contains("package manifest created"))
    XCTAssertTrue(initialize.stdout.contains("Manifest: \(packageSource.appendingPathComponent("riela-package.json").path)"))
    XCTAssertTrue(initialize.stdout.contains(
      "Next: riela package pack \(quotedPackageSource)"
    ))

    let archiveURL = tempDir.appendingPathComponent("text-demo.rielapkg")
    let quotedArchive = "'\(archiveURL.path)'"
    let pack = await app.run([
      "package", "pack", packageSource.path,
      "--destination", archiveURL.path,
      "--working-dir", tempDir.path
    ])
    XCTAssertEqual(pack.exitCode, .success, pack.stderr)
    XCTAssertTrue(pack.stdout.contains("package archive created"))
    XCTAssertTrue(pack.stdout.contains("Archive: \(archiveURL.path)"))
    XCTAssertTrue(pack.stdout.contains("Next: riela package validate \(quotedArchive)"))
    XCTAssertTrue(pack.stdout.contains("RielaApp: Add Workflow/Package..."))
    XCTAssertTrue(pack.stdout.contains("launch RielaApp with --import-workflow-or-package \(quotedArchive)"))
    XCTAssertTrue(pack.stdout.contains("--import-workflow-or-package \(quotedArchive)"))
    XCTAssertTrue(pack.stdout.contains("--import-workflow-or-package \(quotedArchive) --open-workflows"))

    let validate = await app.run([
      "package", "validate", archiveURL.path,
      "--working-dir", tempDir.path
    ])
    XCTAssertEqual(validate.exitCode, .success, validate.stderr)
    XCTAssertTrue(validate.stdout.contains("package validation passed"))
    XCTAssertTrue(validate.stdout.contains("Input: \(archiveURL.path)"))
    XCTAssertTrue(validate.stdout.contains("RielaApp: Add Workflow/Package..."))
    XCTAssertTrue(validate.stdout.contains("launch RielaApp with --import-workflow-or-package \(quotedArchive)"))
    XCTAssertTrue(validate.stdout.contains("--import-workflow-or-package \(quotedArchive)"))
    XCTAssertTrue(validate.stdout.contains("--import-workflow-or-package \(quotedArchive) --open-workflows"))

    let install = await app.run([
      "package", "install", archiveURL.path,
      "--working-dir", tempDir.path
    ])
    XCTAssertEqual(install.exitCode, .success, install.stderr)
    XCTAssertTrue(install.stdout.contains("package install completed"))
    XCTAssertTrue(install.stdout.contains("Package: text-demo 0.1.0 (workflow, valid)"))
    XCTAssertTrue(install.stdout.contains("Installed: \(tempDir.appendingPathComponent(".riela/packages/text-demo").path)"))
    XCTAssertTrue(install.stdout.contains("Next: riela workflow run text-demo --scope project --working-dir '\(tempDir.path)'"))
    XCTAssertTrue(install.stdout.contains("RielaApp: Add Project... and choose \(tempDir.path)"))

    let homeRoot = tempDir.appendingPathComponent("home", isDirectory: true)
    let userInstall = await app.run([
      "package", "install", archiveURL.path,
      "--scope", "user",
      "--overwrite",
      "--working-dir", tempDir.path
    ], environment: ["HOME": homeRoot.path])
    let userInstalledPackage = homeRoot.appendingPathComponent(".riela/packages/text-demo", isDirectory: true)
    XCTAssertEqual(userInstall.exitCode, .success, userInstall.stderr)
    XCTAssertTrue(userInstall.stdout.contains("package install completed"))
    XCTAssertTrue(userInstall.stdout.contains("Next: riela workflow run text-demo --scope user"))
    XCTAssertTrue(userInstall.stdout.contains(
      "RielaApp: Workflows... > Refresh to show the user package in every profile"
    ))
    XCTAssertTrue(userInstall.stdout.contains(
      "or Add Workflow/Package... and choose \(userInstalledPackage.path)"
    ))
  }

  func testPackagePackValidateInstallAndRunRielaPackageArchive() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-archive-package-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try makeArchivePackageSource(root: root, packageSource: packageSource, packageName: "archive-demo")
    let archiveURL = tempDir.appendingPathComponent("archive-demo.rielapkg")

    let app = RielaCLIApplication()
    let pack = await app.run([
      "package", "pack", packageSource.path,
      "--destination", archiveURL.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(pack.exitCode, .success, pack.stderr)
    XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
    let packed = try decodeJSON(WorkflowPackageCommandResult.self, from: pack.stdout)
    XCTAssertEqual(packed.destinationDirectory, archiveURL.path)
    XCTAssertEqual(packed.packages.first?.name, "archive-demo")

    let validate = await app.run([
      "package", "validate", archiveURL.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .success, validate.stdout)
    let validated = try decodeJSON(WorkflowPackageCommandResult.self, from: validate.stdout)
    XCTAssertEqual(validated.packages.first?.valid, true)
    XCTAssertEqual(validated.destinationDirectory, archiveURL.path)
    XCTAssertEqual(validated.packages.first?.packageDirectory, archiveURL.path)

    let install = await app.run([
      "package", "install", archiveURL.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(install.exitCode, .success, install.stdout)
    let installed = try decodeJSON(WorkflowPackageCommandResult.self, from: install.stdout)
    let installedDirectory = tempDir.appendingPathComponent(".riela/packages/archive-demo", isDirectory: true)
    XCTAssertEqual(installed.destinationDirectory, installedDirectory.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: installedDirectory.appendingPathComponent("riela-package.json").path))

    let run = await app.run([
      "package", "run", "archive-demo",
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .success, run.stdout)
    let runResult = try decodeJSON(WorkflowPackageCommandResult.self, from: run.stdout)
    XCTAssertNotNil(runResult.runSessionId)
  }

  func testPackageValidateAndInstallResolveRelativeArchiveAgainstWorkingDirectory() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-validate-relative-guidance-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try makeArchivePackageSource(root: root, packageSource: packageSource, packageName: "relative-guidance-demo")
    let archiveURL = tempDir.appendingPathComponent("relative-guidance-demo.rielapkg")
    try WorkflowPackageArchiveManager().createArchive(from: packageSource, to: archiveURL)

    let app = RielaCLIApplication()
    let validate = await app.run([
      "package", "validate", "relative-guidance-demo.rielapkg",
      "--working-dir", tempDir.path
    ])

    XCTAssertEqual(validate.exitCode, .success, validate.stderr)
    XCTAssertTrue(validate.stdout.contains("Input: \(archiveURL.path)"), validate.stdout)
    XCTAssertTrue(validate.stdout.contains("Add Workflow/Package... and choose \(archiveURL.path)"), validate.stdout)
    XCTAssertTrue(
      validate.stdout.contains("--import-workflow-or-package \(shellQuotedTestArgument(archiveURL.path)) --open-workflows"),
      validate.stdout
    )

    let install = await app.run([
      "package", "install", "relative-guidance-demo.rielapkg",
      "--working-dir", tempDir.path
    ])
    let installedURL = tempDir.appendingPathComponent(".riela/packages/relative-guidance-demo", isDirectory: true)

    XCTAssertEqual(install.exitCode, .success, install.stderr)
    XCTAssertTrue(FileManager.default.fileExists(atPath: installedURL.appendingPathComponent("riela-package.json").path))
    XCTAssertTrue(install.stdout.contains("Installed: \(installedURL.path)"), install.stdout)
    XCTAssertTrue(
      install.stdout.contains("Next: riela workflow run relative-guidance-demo --scope project --working-dir \(tempDir.path)"),
      install.stdout
    )
  }

  func testPackagePackAndValidateZipArchive() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-zip-package-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try makeArchivePackageSource(root: root, packageSource: packageSource, packageName: "zip-demo")
    let archiveURL = tempDir.appendingPathComponent("zip-demo.zip")

    let app = RielaCLIApplication()
    let pack = await app.run([
      "package", "pack", packageSource.path,
      "--destination", archiveURL.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(pack.exitCode, .success, pack.stderr)

    let validate = await app.run([
      "package", "validate", archiveURL.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .success, validate.stdout)
    let validated = try decodeJSON(WorkflowPackageCommandResult.self, from: validate.stdout)
    XCTAssertEqual(validated.packages.first?.name, "zip-demo")
    XCTAssertEqual(validated.packages.first?.valid, true)
  }

  func testPackageValidateReportsMissingArchivePathClearly() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-missing-archive-\(UUID().uuidString)", isDirectory: true)
    let archiveURL = tempDir.appendingPathComponent("missing.rielapkg")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let app = RielaCLIApplication()
    let text = await app.run([
      "package", "validate", archiveURL.path,
      "--working-dir", tempDir.path
    ])
    let json = await app.run([
      "package", "validate", archiveURL.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertEqual(text.exitCode, .failure)
    XCTAssertTrue(text.stderr.contains("Package archive does not exist: \(archiveURL.path)"), text.stderr)
    XCTAssertFalse(text.stderr.contains("zipinfo"), text.stderr)
    XCTAssertEqual(json.exitCode, .failure)
    let failure = try decodeJSON(CLIUnsupportedCommandResult.self, from: json.stdout)
    XCTAssertEqual(failure.error, "Package archive does not exist: \(archiveURL.path)")
  }

  func testPackageInstallSourceArchiveUsesManifestName() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-source-archive-package-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try makeArchivePackageSource(root: root, packageSource: packageSource, packageName: "source-archive-demo")
    let archiveURL = tempDir.appendingPathComponent("source-archive-demo.rielapkg")
    try WorkflowPackageArchiveManager().createArchive(from: packageSource, to: archiveURL)

    let app = RielaCLIApplication()
    let install = await app.run([
      "package", "install",
      "--source", archiveURL.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertEqual(install.exitCode, .success, install.stderr)
    let installed = try decodeJSON(WorkflowPackageCommandResult.self, from: install.stdout)
    let installedDirectory = tempDir.appendingPathComponent(".riela/packages/source-archive-demo", isDirectory: true)
    XCTAssertEqual(installed.destinationDirectory, installedDirectory.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: installedDirectory.appendingPathComponent("riela-package.json").path))
  }

  func testPackagePackRejectsHiddenSymlink() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-hidden-symlink-package-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try makeArchivePackageSource(root: root, packageSource: packageSource, packageName: "hidden-link-demo")
    try FileManager.default.createSymbolicLink(
      at: packageSource.appendingPathComponent(".hidden-link"),
      withDestinationURL: tempDir
    )
    let archiveURL = tempDir.appendingPathComponent("hidden-link-demo.rielapkg")

    let app = RielaCLIApplication()
    let pack = await app.run([
      "package", "pack", packageSource.path,
      "--destination", archiveURL.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertNotEqual(pack.exitCode, .success)
    XCTAssertTrue(
      (pack.stdout + pack.stderr).contains("Package archive contains an unsafe entry"),
      pack.stdout + pack.stderr
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
  }

  func testPackageValidateRejectsArchiveTraversalBeforeExtraction() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-traversal-package-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try makeArchivePackageSource(root: root, packageSource: packageSource, packageName: "traversal-demo")
    try "escape".write(to: tempDir.appendingPathComponent("escape.txt"), atomically: true, encoding: .utf8)
    let archiveURL = tempDir.appendingPathComponent("traversal-demo.zip")
    try runZip(arguments: ["-qry", archiveURL.path, ".", "../escape.txt"], currentDirectory: packageSource)

    let app = RielaCLIApplication()
    let validate = await app.run([
      "package", "validate", archiveURL.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertNotEqual(validate.exitCode, .success)
    XCTAssertTrue(
      (validate.stdout + validate.stderr).contains("Package archive contains an unsafe entry"),
      validate.stdout + validate.stderr
    )
    let extractionRoot = tempDir.appendingPathComponent(".riela/tmp/rielapkg", isDirectory: true)
    let extractionChildren = (try? FileManager.default.contentsOfDirectory(
      at: extractionRoot,
      includingPropertiesForKeys: nil
    )) ?? []
    XCTAssertEqual(extractionChildren, [])
  }

  func testPackageValidateRejectsSiblingBesideTopLevelPackageDirectory() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-top-level-sibling-package-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-dir", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try makeArchivePackageSource(root: root, packageSource: packageSource, packageName: "sibling-demo")
    try "extra".write(to: tempDir.appendingPathComponent("sibling.txt"), atomically: true, encoding: .utf8)
    let archiveURL = tempDir.appendingPathComponent("sibling-demo.zip")
    try runZip(arguments: ["-qry", archiveURL.path, "package-dir", "sibling.txt"], currentDirectory: tempDir)

    let app = RielaCLIApplication()
    let validate = await app.run([
      "package", "validate", archiveURL.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertNotEqual(validate.exitCode, .success)
    XCTAssertTrue(
      (validate.stdout + validate.stderr).contains("Package archive does not contain riela-package.json"),
      validate.stdout + validate.stderr
    )
  }

  private func makeArchivePackageSource(root: String, packageSource: URL, packageName: String) throws {
    try FileManager.default.createDirectory(at: packageSource, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/workflow.json"),
      to: packageSource.appendingPathComponent("workflow.json")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/nodes"),
      to: packageSource.appendingPathComponent("nodes")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/prompts"),
      to: packageSource.appendingPathComponent("prompts")
    )
    let checksum = try WorkflowPackageChecksum.md5(packageRoot: packageSource)
    try """
    {
      "name": "\(packageName)",
      "version": "1.0.0",
      "description": "Archive package",
      "tags": ["archive"],
      "registry": "local",
      "checksum": "\(checksum)",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: packageSource.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
  }

  private func checksum(in manifestURL: URL) throws -> String {
    let data = try Data(contentsOf: manifestURL)
    let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try XCTUnwrap(manifest["checksum"] as? String)
  }

  private func runZip(arguments: [String], currentDirectory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }

  private func shellQuotedTestArgument(_ value: String) -> String {
    let safeScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-=.,/:@%")
    if value.unicodeScalars.allSatisfy({ safeScalars.contains($0) }) {
      return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
