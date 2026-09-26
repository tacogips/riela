import Foundation
import RielaAddons
import RielaCore
import XCTest
@testable import RielaCLI

final class WorkflowInstalledAddonMetadataTests: XCTestCase {
  func testInstalledWorkflowSelectionsRetainOwningManifest() throws {
    let fixture = try InstalledAddonFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let resolver = FileSystemWorkflowBundleResolver()
      for options in [
        WorkflowResolutionOptions(workflowName: fixture.packageId, scope: .project,
          workingDirectory: fixture.project.path),
        WorkflowResolutionOptions(workflowName: fixture.workflowId, scope: .project,
          workingDirectory: fixture.project.path),
        WorkflowResolutionOptions(workflowName: fixture.workflowId,
          workflowDefinitionDir: fixture.workflowDirectory.path,
          workingDirectory: fixture.project.path)
      ] {
        let bundle = try resolver.resolve(options)
        XCTAssertEqual(bundle.workflow.workflowId, fixture.workflowId)
        XCTAssertEqual(bundle.packageManifest?.name, fixture.packageId)
        XCTAssertEqual(bundle.packageDirectory, fixture.packageDirectory.path)
      }
    }
  }

  func testInstalledNativeAddonValidatesAndInspectsWithoutHostExecutable() async throws {
    let fixture = try InstalledAddonFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let resolver = FileSystemWorkflowBundleResolver()
      for options in [
        WorkflowResolutionOptions(workflowName: fixture.packageId, scope: .project,
          workingDirectory: fixture.project.path),
        WorkflowResolutionOptions(workflowName: fixture.workflowId, scope: .project,
          workingDirectory: fixture.project.path),
        WorkflowResolutionOptions(workflowName: fixture.workflowId,
          workflowDefinitionDir: fixture.workflowDirectory.path,
          workingDirectory: fixture.project.path)
      ] {
        let validate = await WorkflowValidateCommand(resolver: resolver).run(WorkflowValidateOptions(
          workflowName: options.workflowName, resolution: options, output: .json
        ))
        XCTAssertEqual(validate.exitCode, .success, validate.stdout)
        let validationJSON = try XCTUnwrap(JSONSerialization.jsonObject(
          with: Data(validate.stdout.utf8)
        ) as? [String: Any])
        XCTAssertEqual(validationJSON["packageName"] as? String, fixture.packageId)
        XCTAssertFalse(validate.stdout.contains("unresolvedAddonExecutable"), validate.stdout)
        let inspect = await WorkflowInspectCommand(resolver: resolver).run(WorkflowInspectOptions(
          workflowName: options.workflowName, resolution: options, output: .json
        ))
        XCTAssertEqual(inspect.exitCode, .success, inspect.stdout)
        let inspectionJSON = try XCTUnwrap(JSONSerialization.jsonObject(
          with: Data(inspect.stdout.utf8)
        ) as? [String: Any])
        let nativeAddons = try XCTUnwrap(inspectionJSON["nativeBundleAddons"] as? [[String: Any]])
        XCTAssertEqual(nativeAddons.first?["packageName"] as? String, "@issue117/youtube-tools")
        XCTAssertEqual(nativeAddons.first?["contentDigest"] as? String, fixture.contentDigest)
        XCTAssertEqual(nativeAddons.first?["dependencyClosureDigest"] as? String, fixture.contentDigest)
        XCTAssertFalse(inspect.stdout.contains("unresolvedAddonExecutable"), inspect.stdout)
      }
    }
  }

  func testCopiedDirectWorkflowDoesNotInheritDependency() async throws {
    let fixture = try InstalledAddonFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let copied = fixture.project.appendingPathComponent("copied", isDirectory: true)
    try FileManager.default.copyItem(at: fixture.workflowDirectory, to: copied)
    let options = WorkflowResolutionOptions(workflowName: fixture.workflowId,
      workflowDefinitionDir: copied.path, workingDirectory: fixture.project.path)
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let bundle = try FileSystemWorkflowBundleResolver().resolve(options)
      XCTAssertNil(bundle.packageManifest)
      let result = await WorkflowValidateCommand().run(WorkflowValidateOptions(
        workflowName: fixture.workflowId, resolution: options, output: .json
      ))
      XCTAssertEqual(result.exitCode, .failure, result.stdout)
      XCTAssertTrue(result.stdout.contains("unresolvedAddonExecutable"), result.stdout)
    }
  }

  func testMismatchedInstalledDependenciesFailClosedInValidateAndInspect() async throws {
    let cases = [
      "missing", "packageIdentity", "packageVersion", "addonVersion", "digest",
      "executionKind", "integrity", "registry", "unknown", "ambiguous", "lowerPriority"
    ]
    for testCase in cases {
      let fixture = try InstalledAddonFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      switch testCase {
      case "missing":
        try FileManager.default.removeItem(at: fixture.dependencyDirectory)
      case "packageIdentity":
        try fixture.updateDependency { $0.name = "@issue117/impostor" }
      case "packageVersion":
        try fixture.updateLock { $0.packages["@issue117/youtube-tools"]?.version = "2.0.0" }
      case "addonVersion":
        try fixture.updateOwner { $0.dependencies[0].addons[0].version = "2" }
      case "digest":
        try fixture.updateOwner { $0.dependencies[0].addons[0].contentDigest = "sha256:" + String(repeating: "b", count: 64) }
      case "executionKind":
        try fixture.updateOwner { $0.dependencies[0].addons[0].executionKind = .container }
      case "integrity":
        try "changed bundle\n".write(to: fixture.dependencyDirectory
          .appendingPathComponent("addons/download-video/DownloadVideo.bundle"),
          atomically: true, encoding: .utf8)
      case "registry":
        try fixture.updateOwner { $0.dependencies[0].registry = "other-registry" }
      case "unknown":
        try fixture.writeWorkflow(addonName: "unknown-addon")
      case "ambiguous":
        try fixture.writeWorkflow(addonName: "download-video")
        try fixture.updateOwner { manifest in
          manifest.dependencies.append(WorkflowPackageDependency(
            packageId: "@issue117/other-tools", kind: .nodeAddon,
            addons: [manifest.dependencies[0].addons[0]]
          ))
        }
      case "lowerPriority":
        let userDependency = fixture.home.appendingPathComponent(
          ".riela/packages/@issue117/youtube-tools", isDirectory: true
        )
        try FileManager.default.createDirectory(at: userDependency.deletingLastPathComponent(),
          withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.dependencyDirectory, to: userDependency)
        try FileManager.default.removeItem(at: fixture.dependencyDirectory)
      default:
        XCTFail("unexpected matrix case")
      }
      let options = WorkflowResolutionOptions(workflowName: fixture.workflowId,
        scope: .project, workingDirectory: fixture.project.path)
      try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
        let validate = await WorkflowValidateCommand().run(WorkflowValidateOptions(
          workflowName: fixture.workflowId, resolution: options, output: .json
        ))
        XCTAssertEqual(validate.exitCode, .failure, "\(testCase): \(validate.stdout)")
        XCTAssertTrue(validate.stdout.contains("unresolvedAddonExecutable"), "\(testCase): \(validate.stdout)")
        let inspect = await WorkflowInspectCommand().run(WorkflowInspectOptions(
          workflowName: fixture.workflowId, resolution: options, output: .json
        ))
        XCTAssertEqual(inspect.exitCode, .failure, "\(testCase): \(inspect.stdout)")
        XCTAssertTrue(inspect.stdout.contains("unresolvedAddonExecutable"), "\(testCase): \(inspect.stdout)")
      }
    }
  }

  func testReachableCalleeUsesItsOwnInstalledPackageContext() async throws {
    let fixture = try InstalledAddonFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let caller = fixture.project.appendingPathComponent(".riela/workflows/caller", isDirectory: true)
    try FileManager.default.createDirectory(at: caller, withIntermediateDirectories: true)
    let callerFile = caller.appendingPathComponent("workflow.json")
    func writeCaller(callee: String) throws {
      try """
      {
        "workflowId": "caller",
        "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
        "entryStepId": "call",
        "nodes": [{ "id": "call-node", "addon": { "name": "riela/kv-get", "version": "1" } }],
        "steps": [{ "id": "call", "nodeId": "call-node", "role": "worker",
          "transitions": [{ "toStepId": "run", "toWorkflowId": "\(callee)" }] }]
      }
      """.write(to: callerFile, atomically: true, encoding: .utf8)
    }
    let options = WorkflowResolutionOptions(workflowName: "caller", scope: .project,
      workingDirectory: fixture.project.path)
    try writeCaller(callee: fixture.workflowId)
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let result = await WorkflowValidateCommand().run(WorkflowValidateOptions(
        workflowName: "caller", resolution: options, output: .json
      ))
      XCTAssertEqual(result.exitCode, .failure, result.stdout)
      XCTAssertTrue(result.stdout.contains("cross-workflow transitions"), result.stdout)
      XCTAssertFalse(result.stdout.contains("unresolvedAddonExecutable"), result.stdout)
    }

    let copied = fixture.project.appendingPathComponent(".riela/workflows/copied-callee", isDirectory: true)
    try FileManager.default.copyItem(at: fixture.workflowDirectory, to: copied)
    let copiedFile = copied.appendingPathComponent("workflow.json")
    let copiedJSON = try String(contentsOf: copiedFile, encoding: .utf8)
    try copiedJSON.replacingOccurrences(of: "youtube-flow", with: "copied-callee")
      .write(to: copiedFile, atomically: true, encoding: .utf8)
    try writeCaller(callee: "copied-callee")
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let result = await WorkflowValidateCommand().run(WorkflowValidateOptions(
        workflowName: "caller", resolution: options, output: .json
      ))
      XCTAssertEqual(result.exitCode, .failure, result.stdout)
      XCTAssertTrue(result.stdout.contains("unresolvedAddonExecutable"), result.stdout)
    }
  }

  func testInstalledDependencyKeepsPackageAndNodeEnvironmentRequirements() async throws {
    let fixture = try InstalledAddonFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.updateOwner { manifest in
      manifest.environmentVariables = [WorkflowPackageEnvironmentVariable(name: "PACKAGE_TOKEN")]
    }
    try fixture.setNodeRequiredEnvironment()
    let options = WorkflowResolutionOptions(workflowName: fixture.workflowId,
      scope: .project, workingDirectory: fixture.project.path)
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let resolver = FileSystemWorkflowBundleResolver()
      let bundle = try resolver.resolve(options)
      let maps = try await reachableWorkflowMaps(bundle: bundle, resolution: options, resolver: resolver)
      XCTAssertEqual(maps.nodeHostRequirements[fixture.workflowId]?["download-video"]?.requiredEnvironment,
        ["NODE_TOKEN", "PACKAGE_TOKEN"])
      for (environment, expectedExit) in [
        ([:], CLIExitCode.failure),
        (["PACKAGE_TOKEN": true, "NODE_TOKEN": true], CLIExitCode.success)
      ] {
        let host = HostCapabilitySnapshot(hostId: "local", backends: [],
          environment: environment, refreshedAt: Date())
        let command = WorkflowValidateCommand(
          resolver: FileSystemWorkflowBundleResolver(),
          hostResolver: HostValidationCapabilityResolver(snapshot: host)
        )
        let result = await command.run(WorkflowValidateOptions(
          workflowName: fixture.workflowId, resolution: options, output: .json,
          host: "local", strictHost: true
        ))
        XCTAssertEqual(result.exitCode, expectedExit, result.stdout)
        XCTAssertFalse(result.stdout.contains("unresolvedAddonExecutable"), result.stdout)
      }
    }
  }

  func testProjectAndUserInstalledWorkflowCollisionPreservesScopePrecedence() throws {
    let fixture = try InstalledAddonFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let userPackage = fixture.home.appendingPathComponent(
      ".riela/packages/@issue117/youtube-flow", isDirectory: true
    )
    try FileManager.default.createDirectory(at: userPackage.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixture.packageDirectory, to: userPackage)
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let resolver = FileSystemWorkflowBundleResolver()
      let automatic = try resolver.resolve(WorkflowResolutionOptions(
        workflowName: fixture.workflowId, scope: .auto, workingDirectory: fixture.project.path
      ))
      XCTAssertEqual(automatic.sourceScope, .project)
      XCTAssertEqual(automatic.packageDirectory, fixture.packageDirectory.path)
      let user = try resolver.resolve(WorkflowResolutionOptions(
        workflowName: fixture.workflowId, scope: .user, workingDirectory: fixture.project.path
      ))
      XCTAssertEqual(user.sourceScope, .user)
      XCTAssertEqual(user.packageDirectory, userPackage.path)
    }
  }

  func testAmbiguousProjectWorkflowDoesNotFallThroughToUserPackage() async throws {
    let fixture = try InstalledAddonFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let otherProjectPackage = fixture.packageDirectory.deletingLastPathComponent()
      .appendingPathComponent("other-flow", isDirectory: true)
    try FileManager.default.copyItem(at: fixture.packageDirectory, to: otherProjectPackage)
    let manifestURL = otherProjectPackage.appendingPathComponent("riela-package.json")
    var manifest = try JSONDecoder().decode(WorkflowPackageManifest.self, from: Data(contentsOf: manifestURL))
    manifest.name = "@issue117/other-flow"
    manifest.checksum = try WorkflowPackageChecksum.md5(packageRoot: otherProjectPackage)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: manifestURL)

    let userPackage = fixture.home.appendingPathComponent(
      ".riela/packages/@issue117/youtube-flow", isDirectory: true
    )
    try FileManager.default.createDirectory(at: userPackage.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixture.packageDirectory, to: userPackage)
    let automatic = WorkflowResolutionOptions(workflowName: fixture.workflowId,
      scope: .auto, workingDirectory: fixture.project.path)
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let resolver = FileSystemWorkflowBundleResolver()
      XCTAssertThrowsError(try resolver.resolve(automatic)) { error in
        XCTAssertTrue(String(describing: error).contains("ambiguous"), "\(error)")
      }
      let validate = await WorkflowValidateCommand(resolver: resolver).run(WorkflowValidateOptions(
        workflowName: fixture.workflowId, resolution: automatic, output: .json
      ))
      XCTAssertNotEqual(validate.exitCode, .success, validate.stdout)
      XCTAssertTrue(validate.stdout.contains("ambiguous"), validate.stdout)
      let inspect = await WorkflowInspectCommand(resolver: resolver).run(WorkflowInspectOptions(
        workflowName: fixture.workflowId, resolution: automatic, output: .json
      ))
      XCTAssertNotEqual(inspect.exitCode, .success, inspect.stdout)
      XCTAssertTrue(inspect.stdout.contains("ambiguous"), inspect.stdout)
      let user = try resolver.resolve(WorkflowResolutionOptions(workflowName: fixture.workflowId,
        scope: .user, workingDirectory: fixture.project.path))
      XCTAssertEqual(user.packageDirectory, userPackage.path)
    }
  }

  func testUnqualifiedUniqueAndQualifiedExactDependencyReferences() async throws {
    let fixture = try InstalledAddonFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let options = WorkflowResolutionOptions(workflowName: fixture.workflowId,
      scope: .project, workingDirectory: fixture.project.path)
    try fixture.writeWorkflow(addonName: "download-video")
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let result = await WorkflowValidateCommand().run(WorkflowValidateOptions(
        workflowName: fixture.workflowId, resolution: options, output: .json
      ))
      XCTAssertEqual(result.exitCode, .success, result.stdout)
    }
    try fixture.writeWorkflow(addonName: "@issue117/youtube-tools/download-video")
    try fixture.updateOwner { manifest in
      let sameNameLock = manifest.dependencies[0].addons[0]
      manifest.dependencies.append(WorkflowPackageDependency(
        packageId: "@issue117/other-tools", kind: .nodeAddon,
        addons: [sameNameLock]
      ))
    }
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let result = await WorkflowValidateCommand().run(WorkflowValidateOptions(
        workflowName: fixture.workflowId, resolution: options, output: .json
      ))
      XCTAssertEqual(result.exitCode, .success, result.stdout)
    }
  }
}

private struct InstalledAddonFixture {
  let root: URL
  let project: URL
  let home: URL
  let packageDirectory: URL
  let workflowDirectory: URL
  let dependencyDirectory: URL
  let contentDigest: String
  let packageId = "@issue117/youtube-flow"
  let workflowId = "youtube-flow"

  init() throws {
    let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    root = repository.appendingPathComponent("tmp/issue-117/tests/\(UUID().uuidString)", isDirectory: true)
    project = root.appendingPathComponent("project", isDirectory: true)
    home = root.appendingPathComponent("home", isDirectory: true)
    packageDirectory = project.appendingPathComponent(".riela/packages/@issue117/youtube-flow", isDirectory: true)
    workflowDirectory = packageDirectory.appendingPathComponent("workflows/youtube-flow", isDirectory: true)
    dependencyDirectory = project.appendingPathComponent(".riela/packages/@issue117/youtube-tools", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    let addonRoot = dependencyDirectory.appendingPathComponent("addons/download-video", isDirectory: true)
    try FileManager.default.createDirectory(at: addonRoot, withIntermediateDirectories: true)
    let bundleURL = addonRoot.appendingPathComponent("DownloadVideo.bundle")
    try "synthetic native bundle\n".write(to: bundleURL, atomically: true, encoding: .utf8)
    let digest = try sha256Digest(for: bundleURL)
    contentDigest = digest
    var dependencyManifest = WorkflowPackageManifest(
      name: "@issue117/youtube-tools", version: "1.0.0", kind: .nodeAddon,
      description: "Synthetic YouTube tools", registry: "local",
      checksum: "pending", checksumAlgorithm: "md5",
      nodeAddons: [WorkflowPackageNodeAddon(
        name: "download-video", version: "1", sourcePath: "addons/download-video",
        execution: WorkflowPackageAddonExecutionDescriptor(kind: .nativeBundle,
          entrypoint: "DownloadVideo.bundle", abiVersion: 1,
          bundleIdentifier: "dev.issue117.download"),
        capabilities: [WorkflowAddonCapability(name: "attachment.read", scope: "attachments/input")],
        contentDigest: digest
      )]
    )
    dependencyManifest.checksum = try WorkflowPackageChecksum.md5(packageRoot: dependencyDirectory)
    try Self.writeManifest(dependencyManifest, to: dependencyDirectory)
    try """
    {
      "workflowId": "youtube-flow",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "run",
      "nodes": [{ "id": "download-video", "addon": { "name": "@issue117/youtube-tools/download-video" } }],
      "steps": [{ "id": "run", "nodeId": "download-video", "role": "worker" }]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    var ownerManifest = WorkflowPackageManifest(
      name: packageId, version: "1.0.0", description: "YouTube fixture",
      registry: "local", checksum: "pending", checksumAlgorithm: "md5",
      workflowDirectory: "workflows/youtube-flow",
      dependencies: [WorkflowPackageDependency(packageId: dependencyManifest.name, kind: .nodeAddon,
        addons: [WorkflowPackageManifestAddonDependencyLock(
          name: "download-video", version: "1", contentDigest: digest,
          executionKind: .nativeBundle, abiVersion: 1,
          bundleIdentifier: "dev.issue117.download", dependencyClosureDigest: digest,
          sourceScope: "project"
        )])]
    )
    ownerManifest.checksum = try WorkflowPackageChecksum.md5(packageRoot: packageDirectory)
    try Self.writeManifest(ownerManifest, to: packageDirectory)
    let entry = try workflowPackageLockEntry(manifest: dependencyManifest,
      sourceReference: dependencyManifest.name, sourceKind: "installed", archiveURL: nil)
    let lockfile = WorkflowPackageLockFile(packages: [dependencyManifest.name: entry])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(lockfile).write(to: project.appendingPathComponent("riela-lock.json"))
  }

  private static func writeManifest(_ manifest: WorkflowPackageManifest, to directory: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: directory.appendingPathComponent("riela-package.json"))
  }

  func updateOwner(_ transform: (inout WorkflowPackageManifest) -> Void) throws {
    let url = packageDirectory.appendingPathComponent("riela-package.json")
    var manifest = try JSONDecoder().decode(WorkflowPackageManifest.self, from: Data(contentsOf: url))
    transform(&manifest)
    manifest.checksum = try WorkflowPackageChecksum.md5(packageRoot: packageDirectory)
    try Self.writeManifest(manifest, to: packageDirectory)
  }

  func updateDependency(_ transform: (inout WorkflowPackageManifest) -> Void) throws {
    let url = dependencyDirectory.appendingPathComponent("riela-package.json")
    var manifest = try JSONDecoder().decode(WorkflowPackageManifest.self, from: Data(contentsOf: url))
    transform(&manifest)
    manifest.checksum = try WorkflowPackageChecksum.md5(packageRoot: dependencyDirectory)
    try Self.writeManifest(manifest, to: dependencyDirectory)
  }

  func updateLock(_ transform: (inout WorkflowPackageLockFile) -> Void) throws {
    let url = project.appendingPathComponent("riela-lock.json")
    var lockfile = try JSONDecoder().decode(WorkflowPackageLockFile.self, from: Data(contentsOf: url))
    transform(&lockfile)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(lockfile).write(to: url)
  }

  func writeWorkflow(addonName: String) throws {
    let url = workflowDirectory.appendingPathComponent("workflow.json")
    var workflow = try XCTUnwrap(JSONSerialization.jsonObject(
      with: Data(contentsOf: url)
    ) as? [String: Any])
    var nodes = try XCTUnwrap(workflow["nodes"] as? [[String: Any]])
    var addon = try XCTUnwrap(nodes[0]["addon"] as? [String: Any])
    addon["name"] = addonName
    nodes[0]["addon"] = addon
    workflow["nodes"] = nodes
    try JSONSerialization.data(withJSONObject: workflow, options: [.prettyPrinted, .sortedKeys])
      .write(to: url)
    try updateOwner { _ in }
  }

  func setNodeRequiredEnvironment() throws {
    let url = workflowDirectory.appendingPathComponent("workflow.json")
    var workflow = try XCTUnwrap(JSONSerialization.jsonObject(
      with: Data(contentsOf: url)
    ) as? [String: Any])
    var nodes = try XCTUnwrap(workflow["nodes"] as? [[String: Any]])
    var addon = try XCTUnwrap(nodes[0]["addon"] as? [String: Any])
    addon["env"] = ["TOKEN": ["fromEnv": "NODE_TOKEN"]]
    nodes[0]["addon"] = addon
    workflow["nodes"] = nodes
    try JSONSerialization.data(withJSONObject: workflow, options: [.prettyPrinted, .sortedKeys])
      .write(to: url)
    try updateOwner { _ in }
  }
}
