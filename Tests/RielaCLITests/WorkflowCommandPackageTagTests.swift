import Foundation
import XCTest
@testable import RielaCLI

extension WorkflowCommandTests {
  func testPackageSummaryCarriesTagsAndSearchMatchesTags() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-package-tags-\(UUID().uuidString)", isDirectory: true)
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
    let packageSourceChecksum = try packageChecksum(packageRoot: packageSource)
    try """
    {
      "name": "tagged-package",
      "version": "1.0.0",
      "title": "Tagged Package",
      "description": "Tagged package for semantic review discovery",
      "tags": ["review", "utility"],
      "backends": ["codex-agent"],
      "environmentVariables": [
        {"name": "RIELA_REQUIRED_TOKEN", "description": "Required token", "required": true, "secret": true},
        {"name": "GOOGLE_ACCESS_TOKEN", "description": "Google access token", "required": true, "secret": true},
        {"name": "GOOGLE_APPLICATION_CREDENTIALS", "description": "Google credentials file", "required": true, "secret": true},
        {"name": "GOOGLE_APPLICATION_CREDENTIALS_JSON", "description": "Google credentials JSON", "required": true, "secret": true},
        {"name": "RIELA_OPTIONAL_MODE", "required": false}
      ],
      "registry": "local",
      "checksum": "\(packageSourceChecksum)",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: packageSource.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    let install = await app.run([
      "package", "install", "tagged-package",
      "--source", packageSource.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(install.exitCode, .success, install.stderr)
    let installed = try decodeJSON(WorkflowPackageCommandResult.self, from: install.stdout)
    XCTAssertEqual(installed.packages.first?.tags, ["review", "utility"])
    XCTAssertEqual(installed.packages.first?.description, "Tagged package for semantic review discovery")
    XCTAssertEqual(installed.packages.first?.backends, ["codex-agent"])
    XCTAssertEqual(installed.packages.first?.requiredEnvironment?.map(\.name), [
      "RIELA_REQUIRED_TOKEN",
      "GOOGLE_ACCESS_TOKEN",
      "GOOGLE_APPLICATION_CREDENTIALS",
      "GOOGLE_APPLICATION_CREDENTIALS_JSON"
    ])

    let list = await app.run([
      "package", "list",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(list.exitCode, .success, list.stderr)
    let listed = try decodeJSON(WorkflowPackageCommandResult.self, from: list.stdout)
    XCTAssertEqual(listed.packages.first?.tags, ["review", "utility"])

    let tagSearch = await app.run([
      "package", "search", "utility",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(tagSearch.exitCode, .success, tagSearch.stderr)
    let tagSearchResult = try decodeJSON(WorkflowPackageCommandResult.self, from: tagSearch.stdout)
    XCTAssertEqual(tagSearchResult.packages.map(\.name), ["tagged-package"])
    XCTAssertEqual(tagSearchResult.packages.first?.tags, ["review", "utility"])

    let descriptionSearch = await app.run([
      "package", "search", "semantic review",
      "--backend", "codex-agent",
      "--tag", "review",
      "--limit", "1",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(descriptionSearch.exitCode, .success, descriptionSearch.stderr)
    let descriptionSearchResult = try decodeJSON(WorkflowPackageCommandResult.self, from: descriptionSearch.stdout)
    XCTAssertEqual(descriptionSearchResult.packages.map(\.name), ["tagged-package"])
    XCTAssertEqual(descriptionSearchResult.packages.first?.matchMetadata?.query, "semantic review")
    XCTAssertEqual(descriptionSearchResult.packages.first?.matchMetadata?.fields, ["description"])
    XCTAssertEqual(descriptionSearchResult.packages.first?.cacheMetadata?.source, "installed")

    let tableSearch = await app.run([
      "package", "search", "semantic review",
      "--working-dir", tempDir.path,
      "--output", "table"
    ])
    XCTAssertEqual(tableSearch.exitCode, .success, tableSearch.stderr)
    XCTAssertTrue(tableSearch.stdout.contains("PACKAGE\tWORKFLOW\tREGISTRY\tTAGS\tSUMMARY"))
    XCTAssertTrue(tableSearch.stdout.contains("Tagged package for semantic review discovery"))
  }

  func testPackageSearchUsesRegistryIndexWhenPackageManifestsAreAbsent() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-package-index-\(UUID().uuidString)", isDirectory: true)
    let registry = tempDir.appendingPathComponent("registry", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
    try """
    {
      "schemaVersion": 1,
      "registry": {
        "id": "local",
        "url": "https://github.com/example/riela-packages"
      },
      "packages": [
        {
          "name": "indexed-package",
          "directory": "packages/indexed-package",
          "version": "1.0.0",
          "kind": "workflow",
          "title": "Indexed Package",
          "description": "Searchable from registry index metadata",
          "tags": ["index", "discovery"],
          "workflow": {
            "directory": "workflows/indexed-package"
          },
          "backends": ["codex-agent"],
          "requiredEnvironment": [
            {"name": "INDEXED_TOKEN", "required": true, "secret": true}
          ]
        }
      ]
    }
    """.write(to: registry.appendingPathComponent("registry-index.json"), atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    let search = await app.run([
      "package", "search", "registry index",
      "--local-path", registry.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(search.exitCode, .success, search.stderr)
    let result = try decodeJSON(WorkflowPackageCommandResult.self, from: search.stdout)
    XCTAssertEqual(result.packages.map(\.name), ["indexed-package"])
    XCTAssertEqual(result.packages.first?.packageDirectory, registry.appendingPathComponent("packages/indexed-package").path)
    XCTAssertEqual(result.packages.first?.workflowIds, ["indexed-package"])
    XCTAssertEqual(result.packages.first?.matchMetadata?.fields, ["description"])
    XCTAssertEqual(result.packages.first?.requiredEnvironment?.map(\.name), ["INDEXED_TOKEN"])
    XCTAssertEqual(result.packages.first?.cacheMetadata?.source, "flag")
  }

  // swiftlint:disable:next function_body_length
  func testPackageInstallResolvesRegistryDependenciesAndNoDependenciesOptOut() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-package-dependencies-\(UUID().uuidString)", isDirectory: true)
    let registry = tempDir.appendingPathComponent("registry", isDirectory: true)
    let alternateRegistry = tempDir.appendingPathComponent("alternate-registry", isDirectory: true)
    let dependencyPackage = registry.appendingPathComponent("packages/base-package", isDirectory: true)
    let alternateDependencyPackage = alternateRegistry.appendingPathComponent("packages/base-package", isDirectory: true)
    let metaPackage = registry.appendingPathComponent("packages/meta-package", isDirectory: true)
    let objectMetaPackage = registry.appendingPathComponent("packages/object-meta-package", isDirectory: true)
    let missingMetaPackage = registry.appendingPathComponent("packages/missing-meta-package", isDirectory: true)
    let rollbackPackage = registry.appendingPathComponent("packages/rollback-package", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    for package in [dependencyPackage, alternateDependencyPackage, metaPackage, objectMetaPackage, missingMetaPackage, rollbackPackage] {
      try FileManager.default.createDirectory(at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(
        at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step"),
        to: package
      )
    }
    let dependencyChecksum = try packageChecksum(packageRoot: dependencyPackage)
    try """
    {
      "name": "base-package",
      "version": "1.0.0",
      "description": "Base dependency",
      "tags": ["dependency"],
      "registry": "fixture",
      "checksum": "\(dependencyChecksum)",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: dependencyPackage.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
    let alternateDependencyChecksum = try packageChecksum(packageRoot: alternateDependencyPackage)
    try """
    {
      "name": "base-package",
      "version": "2.0.0",
      "description": "Alternate registry dependency",
      "tags": ["dependency"],
      "registry": "fixture-alt",
      "checksum": "\(alternateDependencyChecksum)",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: alternateDependencyPackage.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
    let metaChecksum = try packageChecksum(packageRoot: metaPackage)
    try """
    {
      "name": "meta-package",
      "version": "1.0.0",
      "description": "Meta package",
      "tags": ["meta"],
      "dependencies": ["base-package"],
      "registry": "fixture",
      "checksum": "\(metaChecksum)",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: metaPackage.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
    let objectMetaChecksum = try packageChecksum(packageRoot: objectMetaPackage)
    try """
    {
      "name": "object-meta-package",
      "version": "1.0.0",
      "description": "Object dependency metadata",
      "tags": ["meta"],
      "dependencies": [{"packageId": "base-package", "registry": "fixture-alt", "branch": "dev"}],
      "registry": "fixture",
      "checksum": "\(objectMetaChecksum)",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: objectMetaPackage.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
    let missingMetaChecksum = try packageChecksum(packageRoot: missingMetaPackage)
    try """
    {
      "name": "missing-meta-package",
      "version": "1.0.0",
      "description": "Missing dependency metadata",
      "tags": ["meta"],
      "dependencies": ["missing-package"],
      "registry": "fixture",
      "checksum": "\(missingMetaChecksum)",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: missingMetaPackage.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
    let rollbackSkillDirectory = rollbackPackage.appendingPathComponent("skills/codex/conflict", isDirectory: true)
    try FileManager.default.createDirectory(at: rollbackSkillDirectory, withIntermediateDirectories: true)
    try "# Conflict\n".write(
      to: rollbackSkillDirectory.appendingPathComponent("SKILL.md"),
      atomically: true,
      encoding: .utf8
    )
    let rollbackChecksum = try packageChecksum(packageRoot: rollbackPackage)
    try """
    {
      "name": "rollback-package",
      "version": "1.0.0",
      "description": "Rollback package",
      "tags": ["rollback"],
      "dependencies": ["base-package"],
      "registry": "fixture",
      "checksum": "\(rollbackChecksum)",
      "checksumAlgorithm": "md5",
      "workflowDirectory": ".",
      "skillDirectory": "skills"
    }
    """.write(to: rollbackPackage.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    let registryAdd = await app.run([
      "package", "registry", "add", "fixture",
      "--registry-url", "https://github.com/tacogips/riela-fixture",
      "--registry-local-path", registry.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(registryAdd.exitCode, .success, registryAdd.stderr)
    let alternateRegistryAdd = await app.run([
      "package", "registry", "add", "fixture-alt",
      "--registry-url", "https://github.com/tacogips/riela-fixture-alt",
      "--registry-local-path", alternateRegistry.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(alternateRegistryAdd.exitCode, .success, alternateRegistryAdd.stderr)

    let dryRunRoot = tempDir.appendingPathComponent("dry-run", isDirectory: true)
    let dryRunInstall = await app.run([
      "package", "install", "meta-package",
      "--registry-url", "https://github.com/tacogips/riela-fixture",
      "--registry-local-path", registry.path,
      "--dry-run",
      "--working-dir", dryRunRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(dryRunInstall.exitCode, .success, dryRunInstall.stderr)
    let dryRunInstalled = try decodeJSON(WorkflowPackageCommandResult.self, from: dryRunInstall.stdout)
    XCTAssertEqual(dryRunInstalled.dependencies?.map(\.installState), ["would-install"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: dryRunRoot.appendingPathComponent(".riela/packages/base-package").path))

    let install = await app.run([
      "package", "install", "meta-package",
      "--registry", "fixture",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(install.exitCode, .success, install.stderr)
    let installed = try decodeJSON(WorkflowPackageCommandResult.self, from: install.stdout)
    XCTAssertEqual(installed.packages.map(\.name), ["meta-package"])
    XCTAssertEqual(installed.dependencies?.map(\.name), ["base-package"])
    XCTAssertEqual(installed.dependencies?.map(\.installState), ["installed"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/packages/base-package").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/packages/meta-package").path))

    let satisfiedDryRun = await app.run([
      "package", "install", "meta-package",
      "--registry", "fixture",
      "--dry-run",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(satisfiedDryRun.exitCode, .success, satisfiedDryRun.stderr)
    let satisfiedDryRunResult = try decodeJSON(WorkflowPackageCommandResult.self, from: satisfiedDryRun.stdout)
    XCTAssertEqual(satisfiedDryRunResult.dependencies?.map(\.installState), ["satisfied"])

    let missingDryRun = await app.run([
      "package", "install", "missing-meta-package",
      "--registry", "fixture",
      "--dry-run",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(missingDryRun.exitCode, .success, missingDryRun.stderr)
    let missingDryRunResult = try decodeJSON(WorkflowPackageCommandResult.self, from: missingDryRun.stdout)
    XCTAssertEqual(missingDryRunResult.dependencies?.map(\.installState), ["missing"])
    XCTAssertEqual(missingDryRunResult.dependencies?.first?.issues.first?.code, "PACKAGE_DEPENDENCY_MISSING")

    let nonEquivalentDependency = await app.run([
      "package", "install", "object-meta-package",
      "--registry", "fixture",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(nonEquivalentDependency.exitCode, .failure)
    XCTAssertTrue(nonEquivalentDependency.stdout.contains("not equivalent"), nonEquivalentDependency.stdout)

    let noDepsRoot = tempDir.appendingPathComponent("no-deps", isDirectory: true)
    let noDepsInstall = await app.run([
      "package", "install", "meta-package",
      "--registry-url", "https://github.com/tacogips/riela-fixture",
      "--registry-local-path", registry.path,
      "--no-dependencies",
      "--working-dir", noDepsRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(noDepsInstall.exitCode, .success, noDepsInstall.stderr)
    let noDepsInstalled = try decodeJSON(WorkflowPackageCommandResult.self, from: noDepsInstall.stdout)
    XCTAssertEqual(noDepsInstalled.dependencies, [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: noDepsRoot.appendingPathComponent(".riela/packages/base-package").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: noDepsRoot.appendingPathComponent(".riela/packages/meta-package").path))

    let objectDependencyRoot = tempDir.appendingPathComponent("object-dependency", isDirectory: true)
    for (id, url, localPath) in [
      ("fixture", "https://github.com/tacogips/riela-fixture", registry.path),
      ("fixture-alt", "https://github.com/tacogips/riela-fixture-alt", alternateRegistry.path)
    ] {
      let registryAdd = await app.run([
        "package", "registry", "add", id,
        "--registry-url", url,
        "--registry-local-path", localPath,
        "--working-dir", objectDependencyRoot.path,
        "--output", "json"
      ])
      XCTAssertEqual(registryAdd.exitCode, .success, registryAdd.stderr)
    }
    let objectDependencyInstall = await app.run([
      "package", "install", "object-meta-package",
      "--registry", "fixture",
      "--working-dir", objectDependencyRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(objectDependencyInstall.exitCode, .success, objectDependencyInstall.stderr)
    let objectDependencyResult = try decodeJSON(WorkflowPackageCommandResult.self, from: objectDependencyInstall.stdout)
    XCTAssertEqual(objectDependencyResult.dependencies?.map(\.version), ["2.0.0"])

    let rollbackRoot = tempDir.appendingPathComponent("rollback", isDirectory: true)
    let existingRollbackPackage = rollbackRoot.appendingPathComponent(".riela/packages/rollback-package", isDirectory: true)
    try FileManager.default.createDirectory(at: existingRollbackPackage, withIntermediateDirectories: true)
    try "existing".write(to: existingRollbackPackage.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
    let existingSkill = rollbackRoot.appendingPathComponent(".codex/skills/conflict", isDirectory: true)
    try FileManager.default.createDirectory(at: existingSkill, withIntermediateDirectories: true)
    try "# Existing\n".write(to: existingSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    let rollback = await app.run([
      "package", "install", "rollback-package",
      "--registry-url", "https://github.com/tacogips/riela-fixture",
      "--registry-local-path", registry.path,
      "--working-dir", rollbackRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(rollback.exitCode, .failure)
    XCTAssertFalse(FileManager.default.fileExists(atPath: rollbackRoot.appendingPathComponent(".riela/packages/base-package").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: existingRollbackPackage.appendingPathComponent("marker.txt").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: existingSkill.appendingPathComponent("SKILL.md").path))

    try """
    {
      "name": "meta-package",
      "version": "1.1.0",
      "description": "Meta package update",
      "tags": ["meta"],
      "dependencies": ["base-package"],
      "registry": "fixture",
      "checksum": "\(metaChecksum)",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: metaPackage.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let updateDryRun = await app.run([
      "package", "update", "meta-package",
      "--registry", "fixture",
      "--dry-run",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(updateDryRun.exitCode, .success, updateDryRun.stderr)
    let dryRunResult = try decodeJSON(WorkflowPackageCommandResult.self, from: updateDryRun.stdout)
    XCTAssertEqual(dryRunResult.packages.first?.previousVersion, "1.0.0")
    XCTAssertEqual(dryRunResult.packages.first?.updateState, "would-update")

    let update = await app.run([
      "package", "update", "meta-package",
      "--registry", "fixture",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(update.exitCode, .success, update.stderr)
    let updateResult = try decodeJSON(WorkflowPackageCommandResult.self, from: update.stdout)
    XCTAssertEqual(updateResult.packages.first?.version, "1.1.0")
    XCTAssertEqual(updateResult.packages.first?.updateState, "updated")

    let upToDate = await app.run([
      "package", "update", "meta-package",
      "--registry", "fixture",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(upToDate.exitCode, .success, upToDate.stderr)
    let upToDateResult = try decodeJSON(WorkflowPackageCommandResult.self, from: upToDate.stdout)
    XCTAssertEqual(upToDateResult.packages.first?.updateState, "up-to-date")

    let failedFetch = await app.run([
      "package", "update", "meta-package",
      "--registry", "fixture-alt",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(failedFetch.exitCode, .success, failedFetch.stderr)
    let failedFetchResult = try decodeJSON(WorkflowPackageCommandResult.self, from: failedFetch.stdout)
    XCTAssertEqual(failedFetchResult.packages.first?.updateState, "failed")
    XCTAssertEqual(failedFetchResult.packages.first?.issues.first?.code, "PACKAGE_UPDATE_SOURCE_NOT_FOUND")
  }

  func testPackageSearchReportsEmptyRootsAndUsesSiblingRegistryFallback() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-package-registry-roots-\(UUID().uuidString)", isDirectory: true)
    let workingDirectory = tempDir.appendingPathComponent("work", isDirectory: true)
    let homeRoot = tempDir.appendingPathComponent("home", isDirectory: true)
    let emptyRegistry = tempDir.appendingPathComponent("empty-registry/packages", isDirectory: true)
    let siblingPackage = URL(fileURLWithPath: "\(workingDirectory.path)-packages", isDirectory: true)
      .appendingPathComponent("packages/sibling-package", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: emptyRegistry, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: siblingPackage.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step"),
      to: siblingPackage
    )
    let siblingChecksum = try packageChecksum(packageRoot: siblingPackage)
    try """
    {
      "name": "sibling-package",
      "version": "1.0.0",
      "description": "Sibling fallback package",
      "tags": ["fallback"],
      "registry": "default",
      "checksum": "\(siblingChecksum)",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: siblingPackage.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    let emptySearch = await app.run([
      "package", "search", "anything",
      "--local-path", emptyRegistry.deletingLastPathComponent().path,
      "--working-dir", workingDirectory.path,
      "--output", "json"
    ], environment: ["HOME": homeRoot.path])
    XCTAssertEqual(emptySearch.exitCode, .failure)
    XCTAssertTrue(emptySearch.stdout.contains("no package manifests found"), emptySearch.stdout)
    XCTAssertTrue(emptySearch.stdout.contains("empty-registry"), emptySearch.stdout)

    let siblingSearch = await app.run([
      "package", "search", "fallback",
      "--working-dir", workingDirectory.path,
      "--output", "json"
    ], environment: ["HOME": homeRoot.path])
    XCTAssertEqual(siblingSearch.exitCode, .success, siblingSearch.stderr)
    let siblingResult = try decodeJSON(WorkflowPackageCommandResult.self, from: siblingSearch.stdout)
    XCTAssertEqual(siblingResult.packages.map(\.name), ["sibling-package"])
    XCTAssertEqual(siblingResult.packages.first?.cacheMetadata?.source, "sibling")
  }
}
