import Foundation
import XCTest
@testable import RielaAddons
@testable import RielaCore

final class WorkflowPackageManifestTests: XCTestCase {
  func testManifestDecodesWithWorkflowDefaultAndDeterministicValidation() throws {
    let data = Data("""
    {
      "name": "@scope/sample_package",
      "version": "1.0.0",
      "description": "Sample workflow package",
      "tags": ["sample"],
      "registry": "default",
      "checksum": "abc123",
      "checksumAlgorithm": "md5",
      "authors": ["Riela"],
      "license": "MIT",
      "repository": "https://example.invalid/repo.git",
      "examples": ["examples/sample"],
      "minimumRielaVersion": "0.1.0",
      "backends": ["codex-agent"],
      "environmentVariables": [
        "RIELA_TOKEN",
        {"name": "RIELA_OPTIONAL_MODE", "description": "Optional mode", "required": false, "secret": false}
      ],
      "workflowDirectory": "workflows/main",
      "loop": {
        "promotionReady": true,
        "usageContract": true,
        "requiredMockScenarios": ["mock-scenario.json"],
        "expectedResults": ["EXPECTED_RESULTS.md"],
        "requiredGates": ["implementation-review"],
        "requiredPolicies": ["runtime-owned-evidence"],
        "minimumEvidenceSchemaVersion": 1
      },
      "skills": [{"vendor": "codex", "name": "use-package", "sourcePath": "skills/use-package/SKILL.md"}],
      "dependencies": ["string-dependency", {"packageId": "shared-package", "kind": "workflow"}],
      "addons": [{"name": "reply", "version": "1.0.0", "sourcePath": "addons/reply", "execution": {"kind": "declarative"}}]
    }
    """.utf8)

    let manifest = try JSONDecoder().decode(WorkflowPackageManifest.self, from: data)

    XCTAssertEqual(manifest.kind, .workflow)
    XCTAssertEqual(manifest.registry, "default")
    XCTAssertEqual(manifest.checksumAlgorithm, "md5")
    XCTAssertEqual(manifest.dependencies.first?.packageId, "string-dependency")
    XCTAssertEqual(manifest.backends, ["codex-agent"])
    XCTAssertEqual(manifest.environmentVariables.first?.name, "RIELA_TOKEN")
    XCTAssertEqual(manifest.environmentVariables.first?.required, true)
    XCTAssertEqual(manifest.environmentVariables.last?.name, "RIELA_OPTIONAL_MODE")
    XCTAssertEqual(manifest.environmentVariables.last?.required, false)
    XCTAssertEqual(manifest.nodeAddons.first?.execution?.kind, .declarative)
    XCTAssertEqual(manifest.loop?.requiredMockScenarios, ["mock-scenario.json"])
    XCTAssertEqual(manifest.loop?.expectedResults, ["EXPECTED_RESULTS.md"])
    XCTAssertEqual(manifest.loop?.minimumEvidenceSchemaVersion, 1)
    XCTAssertEqual(WorkflowPackageManifestValidator.validate(manifest), [])
  }

  func testManifestRejectsUnknownTopLevelKeys() {
    let data = Data(#"{"name":"sample","unsupported":true}"#.utf8)

    XCTAssertThrowsError(try JSONDecoder().decode(WorkflowPackageManifest.self, from: data)) { error in
      XCTAssertTrue(String(describing: error).contains("unsupported key"))
    }
  }

  func testManifestRejectsUnknownNestedKeys() {
    let dependencyData = Data(#"{"name":"sample","dependencies":[{"packageId":"other","unsupported":true}]}"#.utf8)
    let addonData = Data(#"{"name":"sample","addons":[{"name":"reply","version":"1.0.0","sourcePath":"addons/reply","unsupported":true}]}"#.utf8)
    let capabilityData = Data(#"{"name":"sample","addons":[{"name":"reply","version":"1.0.0","sourcePath":"addons/reply","capabilities":[{"name":"network","unsupported":true}]}]}"#.utf8)
    let skillData = Data(#"{"name":"sample","skills":[{"vendor":"codex","name":"skill","sourcePath":"skills/skill/SKILL.md","unsupported":true}]}"#.utf8)
    let workflowData = Data(#"{"name":"sample","workflow":{"description":"sample","unsupported":true}}"#.utf8)
    let integrityData = Data(#"{"name":"sample","integrity":{"digest":"abc","unsupported":true}}"#.utf8)
    let loopData = Data(#"{"name":"sample","loop":{"promotionReady":true,"unsupported":true}}"#.utf8)
    let environmentData = Data(#"{"name":"sample","environmentVariables":[{"name":"TOKEN","unsupported":true}]}"#.utf8)

    XCTAssertThrowsError(try JSONDecoder().decode(WorkflowPackageManifest.self, from: dependencyData))
    XCTAssertThrowsError(try JSONDecoder().decode(WorkflowPackageManifest.self, from: addonData))
    XCTAssertThrowsError(try JSONDecoder().decode(WorkflowPackageManifest.self, from: capabilityData))
    XCTAssertThrowsError(try JSONDecoder().decode(WorkflowPackageManifest.self, from: skillData))
    XCTAssertThrowsError(try JSONDecoder().decode(WorkflowPackageManifest.self, from: workflowData))
    XCTAssertThrowsError(try JSONDecoder().decode(WorkflowPackageManifest.self, from: integrityData))
    XCTAssertThrowsError(try JSONDecoder().decode(WorkflowPackageManifest.self, from: loopData))
    XCTAssertThrowsError(try JSONDecoder().decode(WorkflowPackageManifest.self, from: environmentData))
  }

  func testManifestValidationRejectsInvalidAndDuplicateEnvironmentVariables() {
    let manifest = WorkflowPackageManifest(
      name: "env-package",
      version: "1.0.0",
      description: "Environment package",
      tags: ["env"],
      registry: "local",
      checksum: "abc123",
      checksumAlgorithm: "md5",
      environmentVariables: [
        .init(name: "RIELA_TOKEN"),
        .init(name: "RIELA_TOKEN"),
        .init(name: "1BAD")
      ]
    )

    let issues = WorkflowPackageManifestValidator.validate(manifest)

    XCTAssertTrue(issues.contains { $0.path == "environmentVariables[1].name" })
    XCTAssertTrue(issues.contains { $0.path == "environmentVariables[2].name" })
  }

  func testManifestValidationRequiresDecodedTagsAndRejectsEmptyTags() throws {
    let missingTagsData = Data("""
    {
      "name": "workflow-package",
      "version": "1.0.0",
      "description": "Workflow package",
      "registry": "default",
      "checksum": "abc123",
      "checksumAlgorithm": "md5"
    }
    """.utf8)
    let emptyTagData = Data("""
    {
      "name": "workflow-package",
      "version": "1.0.0",
      "description": "Workflow package",
      "tags": ["valid", ""],
      "registry": "default",
      "checksum": "abc123",
      "checksumAlgorithm": "md5",
      "workflow": {"description": "Workflow metadata", "tags": [""]}
    }
    """.utf8)

    let missingTagsManifest = try JSONDecoder().decode(WorkflowPackageManifest.self, from: missingTagsData)
    let emptyTagManifest = try JSONDecoder().decode(WorkflowPackageManifest.self, from: emptyTagData)

    XCTAssertTrue(WorkflowPackageManifestValidator.validate(missingTagsManifest).contains { $0.path == "tags" })
    let emptyTagIssues = WorkflowPackageManifestValidator.validate(emptyTagManifest)
    XCTAssertTrue(emptyTagIssues.contains { $0.path == "tags[1]" })
    XCTAssertTrue(emptyTagIssues.contains { $0.path == "workflow.tags[0]" })
  }

  func testManifestDecodingRejectsNullTags() {
    let topLevelNullTags = Data("""
    {
      "name": "workflow-package",
      "version": "1.0.0",
      "description": "Workflow package",
      "tags": null,
      "registry": "default",
      "checksum": "abc123",
      "checksumAlgorithm": "md5"
    }
    """.utf8)
    let workflowNullTags = Data("""
    {
      "name": "workflow-package",
      "version": "1.0.0",
      "description": "Workflow package",
      "tags": [],
      "registry": "default",
      "checksum": "abc123",
      "checksumAlgorithm": "md5",
      "workflow": {"description": "Workflow metadata", "tags": null}
    }
    """.utf8)

    XCTAssertThrowsError(try JSONDecoder().decode(WorkflowPackageManifest.self, from: topLevelNullTags))
    XCTAssertThrowsError(try JSONDecoder().decode(WorkflowPackageManifest.self, from: workflowNullTags))
  }

  func testManifestValidationRejectsUnsafeNamesPathsAndAddonLocks() {
    let manifest = WorkflowPackageManifest(
      name: "BadName",
      version: nil,
      description: nil,
      registry: nil,
      checksum: nil,
      checksumAlgorithm: "sha1",
      workflowDirectory: "../outside",
      nodeAddons: [.init(name: "", version: "", sourcePath: "/absolute")],
      skills: [.init(vendor: .codex, name: "", sourcePath: "")],
      dependencies: [.init(packageId: "BadName", kind: .nodeAddon)]
    )

    let issues = WorkflowPackageManifestValidator.validate(manifest)

    XCTAssertEqual(issues.map(\.code), Array(repeating: "INVALID_MANIFEST", count: issues.count))
    XCTAssertTrue(issues.map(\.path).contains("name"))
    XCTAssertTrue(issues.map(\.path).contains("version"))
    XCTAssertTrue(issues.map(\.path).contains("checksumAlgorithm"))
    XCTAssertTrue(issues.map(\.path).contains("workflowDirectory"))
    XCTAssertTrue(issues.map(\.path).contains("dependencies[0].addons"))
  }

  func testNodeAddonManifestValidationRequiresAddonsAndExecutableSafetyMetadata() {
    let executableAddon = WorkflowPackageNodeAddon(
      name: "runner",
      version: "1.0.0",
      sourcePath: "addons/runner",
      execution: .init(kind: .localCommand, entrypoint: "run.sh"),
      capabilities: [],
      contentDigest: nil
    )
    let manifest = WorkflowPackageManifest(
      name: "addon-package",
      version: "1.0.0",
      kind: .nodeAddon,
      description: "Add-on package",
      tags: [],
      registry: "default",
      checksum: "abc123",
      checksumAlgorithm: "md5",
      workflow: .init(description: "must not be present"),
      workflowDirectory: ".",
      nodeAddons: [executableAddon]
    )

    let issues = WorkflowPackageManifestValidator.validate(manifest)

    XCTAssertTrue(issues.map(\.path).contains("workflow"))
    XCTAssertTrue(issues.map(\.path).contains("addons[0].capabilities"))
    XCTAssertTrue(issues.map(\.path).contains("addons[0].contentDigest"))
  }

  func testAddonCapabilityValidationCoversNamesPoliciesSensitiveReasonsDuplicatesAndGrants() {
    let duplicateReadCapability = WorkflowAddonCapability(name: "filesystem.read", scope: "repo")
    let executableAddon = WorkflowPackageNodeAddon(
      name: "runner",
      version: "1.0.0",
      sourcePath: "addons/runner",
      execution: .init(kind: .localCommand, entrypoint: "run.sh"),
      capabilities: [
        .init(name: "network.egress"),
        .init(name: "filesystem.read", scope: "repo", defaultPolicy: "ask"),
        duplicateReadCapability,
        duplicateReadCapability,
        .init(name: "unknown.capability", reason: "unsupported")
      ],
      contentDigest: "sha256:\(String(repeating: "a", count: 64))"
    )
    let dependency = WorkflowPackageDependency(
      packageId: "addon-package",
      kind: .nodeAddon,
      addons: [
        .init(
          name: "runner",
          version: "1.0.0",
          capabilityGrant: [
            "process.spawn": .init(allowed: true, scope: "commands/*"),
            "unknown.capability": .init(allowed: true)
          ]
        )
      ]
    )
    let manifest = WorkflowPackageManifest(
      name: "workflow-package",
      version: "1.0.0",
      description: "Workflow package",
      registry: "default",
      checksum: "abc123",
      checksumAlgorithm: "md5",
      nodeAddons: [executableAddon],
      dependencies: [dependency]
    )

    let issues = WorkflowPackageManifestValidator.validate(manifest)

    XCTAssertTrue(issues.contains { $0.path == "addons[0].capabilities[0].reason" })
    XCTAssertTrue(issues.contains { $0.path == "addons[0].capabilities[1].defaultPolicy" })
    XCTAssertTrue(issues.contains { $0.path == "addons[0].capabilities[3]" })
    XCTAssertTrue(issues.contains { $0.path == "addons[0].capabilities[4].name" })
    XCTAssertTrue(issues.contains { $0.path == "dependencies[0].addons[0].capabilityGrant.process.spawn.scope" })
    XCTAssertTrue(issues.contains { $0.path == "dependencies[0].addons[0].capabilityGrant" })
  }

  func testAddonManifestValidationRejectsUnsafeAddonSourceAndExecutionArtifactPaths() {
    let manifest = validManifest(nodeAddons: [
      .init(name: "dot-source", version: "1.0.0", sourcePath: ".", execution: .init(kind: .declarative)),
      .init(name: "traversal-source", version: "1.0.0", sourcePath: "addons/../runner", execution: .init(kind: .declarative)),
      .init(
        name: "bad-entrypoint",
        version: "1.0.0",
        sourcePath: "addons/bad-entrypoint",
        execution: .init(kind: .localCommand, entrypoint: "../run.sh"),
        capabilities: [.init(name: "process.spawn", reason: "runs package command")],
        contentDigest: "sha256:\(String(repeating: "b", count: 64))"
      ),
      .init(
        name: "bad-containerfile",
        version: "1.0.0",
        sourcePath: "addons/bad-containerfile",
        execution: .init(kind: .container, containerfilePath: "."),
        capabilities: [.init(name: "container.run", reason: "runs package container")],
        contentDigest: "sha256:\(String(repeating: "c", count: 64))"
      )
    ])

    let issues = WorkflowPackageManifestValidator.validate(manifest)

    XCTAssertTrue(issues.contains { $0.path == "addons[0].sourcePath" })
    XCTAssertTrue(issues.contains { $0.path == "addons[1].sourcePath" })
    XCTAssertTrue(issues.contains { $0.path == "addons[2].execution.entrypoint" })
    XCTAssertTrue(issues.contains { $0.path == "addons[3].execution.containerfilePath" })
  }

  func testAddonManifestValidationRejectsMissingExecutableArtifactsAndDeclarativeArtifacts() {
    let manifest = validManifest(nodeAddons: [
      .init(
        name: "missing-artifact",
        version: "1.0.0",
        sourcePath: "addons/missing-artifact",
        execution: .init(kind: .localCommand),
        capabilities: [.init(name: "process.spawn", reason: "runs package command")],
        contentDigest: "sha256:\(String(repeating: "d", count: 64))"
      ),
      .init(
        name: "declarative-artifact",
        version: "1.0.0",
        sourcePath: "addons/declarative-artifact",
        execution: .init(kind: .declarative, entrypoint: "run.sh")
      )
    ])

    let issues = WorkflowPackageManifestValidator.validate(manifest)

    XCTAssertTrue(issues.contains { $0.path == "addons[0].execution" && $0.message.contains("entrypoint or containerfilePath") })
    XCTAssertTrue(issues.contains { $0.path == "addons[1].execution" && $0.message.contains("must not declare executable artifacts") })
  }

  func testContainerAddonManifestDecodesPrebuiltImageMetadata() throws {
    let digest = "sha256:\(String(repeating: "a", count: 64))"
    let data = Data("""
    {
      "name": "container-addon-package",
      "version": "1.0.0",
      "kind": "node-addon",
      "description": "Container add-on package",
      "tags": [],
      "registry": "default",
      "checksum": "abc123",
      "checksumAlgorithm": "md5",
      "addons": [{
        "name": "container-runner",
        "version": "1.0.0",
        "sourcePath": "addons/container-runner",
        "contentDigest": "\(digest)",
        "capabilities": [{"name": "network.egress", "reason": "calls external API"}],
        "execution": {
          "kind": "container",
          "image": "ghcr.io/example/container-runner",
          "imageDigest": "\(digest)",
          "runtimeHints": ["ffmpeg"]
        }
      }]
    }
    """.utf8)

    let manifest = try JSONDecoder().decode(WorkflowPackageManifest.self, from: data)
    let execution = try XCTUnwrap(manifest.nodeAddons.first?.execution)

    XCTAssertEqual(execution.kind, .container)
    XCTAssertEqual(execution.image, "ghcr.io/example/container-runner")
    XCTAssertEqual(execution.imageDigest, digest)
    XCTAssertEqual(execution.runtimeHints, ["ffmpeg"])
    XCTAssertEqual(WorkflowPackageManifestValidator.validate(manifest), [])
  }

  func testContainerAddonManifestRejectsUnsafeImageMetadata() {
    let manifest = validManifest(nodeAddons: [
      .init(
        name: "container-runner",
        version: "1.0.0",
        sourcePath: "addons/container-runner",
        execution: .init(
          kind: .container,
          image: "ghcr.io/example/bad image",
          imageDigest: "sha256:ABC"
        ),
        capabilities: [.init(name: "network.egress", reason: "calls external API")],
        contentDigest: "sha256:\(String(repeating: "b", count: 64))"
      ),
      .init(
        name: "local-runner",
        version: "1.0.0",
        sourcePath: "addons/local-runner",
        execution: .init(
          kind: .localCommand,
          entrypoint: "run.sh",
          image: "ghcr.io/example/local-runner"
        ),
        capabilities: [.init(name: "process.spawn", reason: "runs package command")],
        contentDigest: "sha256:\(String(repeating: "c", count: 64))"
      )
    ])

    let issues = WorkflowPackageManifestValidator.validate(manifest)

    XCTAssertTrue(issues.contains { $0.path == "addons[0].execution.image" })
    XCTAssertTrue(issues.contains { $0.path == "addons[0].execution.imageDigest" })
    XCTAssertTrue(issues.contains { $0.path == "addons[1].execution" && $0.message.contains("container image metadata") })
  }

  func testNativeBundleManifestDecodesAndValidatesRequiredMetadata() throws {
    let data = Data("""
    {
      "name": "native-addon-package",
      "version": "1.0.0",
      "kind": "node-addon",
      "description": "Native add-on package",
      "tags": [],
      "registry": "default",
      "checksum": "abc123",
      "checksumAlgorithm": "md5",
      "addons": [{
        "name": "native-runner",
        "version": "1.0.0",
        "sourcePath": "addons/native-runner",
        "contentDigest": "sha256:\(String(repeating: "e", count: 64))",
        "capabilities": [{"name": "attachment.read", "scope": "attachments/input"}],
        "execution": {
          "kind": "native-bundle",
          "entrypoint": "NativeRunner.bundle",
          "abiVersion": 1,
          "bundleIdentifier": "com.example.riela.NativeRunner",
          "codeSignatureRequirement": "anchor apple generic"
        }
      }]
    }
    """.utf8)

    let manifest = try JSONDecoder().decode(WorkflowPackageManifest.self, from: data)

    XCTAssertEqual(manifest.nodeAddons.first?.execution?.kind, .nativeBundle)
    XCTAssertEqual(manifest.nodeAddons.first?.execution?.abiVersion, 1)
    XCTAssertEqual(manifest.nodeAddons.first?.execution?.bundleIdentifier, "com.example.riela.NativeRunner")
    XCTAssertEqual(WorkflowPackageManifestValidator.validate(manifest), [])
  }

  func testNativeBundleManifestRejectsUnsafeMetadataAndGenericFilesystemCapabilities() {
    let manifest = WorkflowPackageManifest(
      name: "workflow-package",
      version: "1.0.0",
      kind: .workflow,
      description: "Workflow package",
      tags: [],
      registry: "default",
      checksum: "abc123",
      checksumAlgorithm: "md5",
      nodeAddons: [
        .init(
          name: "native-runner",
          version: "1.0.0",
          sourcePath: "addons/native-runner",
          execution: .init(
            kind: .nativeBundle,
            entrypoint: "NativeRunner.dylib",
            containerfilePath: "Containerfile",
            abiVersion: 2,
            bundleIdentifier: "not-reverse-dns",
            codeSignatureRequirement: " "
          ),
          capabilities: [.init(name: "filesystem.read", scope: "repo", reason: "reads repository files")],
          contentDigest: "sha256:\(String(repeating: "f", count: 64))"
        )
      ]
    )

    let issues = WorkflowPackageManifestValidator.validate(manifest)

    XCTAssertTrue(issues.contains { $0.path == "addons[0].execution.kind" })
    XCTAssertTrue(issues.contains { $0.path == "addons[0].execution.entrypoint" && $0.message.contains(".bundle") })
    XCTAssertTrue(issues.contains { $0.path == "addons[0].execution.containerfilePath" })
    XCTAssertTrue(issues.contains { $0.path == "addons[0].execution.abiVersion" })
    XCTAssertTrue(issues.contains { $0.path == "addons[0].execution.bundleIdentifier" })
    XCTAssertTrue(issues.contains { $0.path == "addons[0].execution.codeSignatureRequirement" })
    XCTAssertTrue(issues.contains { $0.path == "addons[0].capabilities[0].name" && $0.message.contains("attachment.read") })
  }

  func testNativeBundleDependencyLocksRejectFilesystemGrantsAndRequireDigest() {
    let dependency = WorkflowPackageDependency(
      packageId: "native-addon-package",
      kind: .nodeAddon,
      addons: [
        .init(
          name: "native-runner",
          version: "1.0.0",
          executionKind: .nativeBundle,
          capabilityGrant: [
            "filesystem.read": .init(allowed: true, scope: "repo"),
            "attachment.read": .init(allowed: true, scope: "attachments/input")
          ]
        )
      ]
    )
    let manifest = WorkflowPackageManifest(
      name: "workflow-package",
      version: "1.0.0",
      description: "Workflow package",
      tags: [],
      registry: "default",
      checksum: "abc123",
      checksumAlgorithm: "md5",
      dependencies: [dependency]
    )

    let issues = WorkflowPackageManifestValidator.validate(manifest)

    XCTAssertTrue(issues.contains { $0.path == "dependencies[0].addons[0].contentDigest" })
    XCTAssertTrue(issues.contains { $0.path == "dependencies[0].addons[0].capabilityGrant.filesystem.read" && $0.message.contains("attachment.read") })
    XCTAssertFalse(issues.contains { $0.path == "dependencies[0].addons[0].capabilityGrant.attachment.read" })
  }

  func testLoaderValidationRequiresWorkflowJsonAtWorkflowDirectory() async throws {
    let packageRoot = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: packageRoot) }
    let workflowDirectory = packageRoot.appendingPathComponent("workflows/main", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    let manifest = WorkflowPackageManifest(
      name: "workflow-package",
      version: "1.0.0",
      description: "Workflow package",
      registry: "default",
      checksum: "abc123",
      checksumAlgorithm: "md5",
      workflowDirectory: "workflows/main"
    )
    let loader = FileWorkflowPackageManifestLoader()

    let missingIssues = await loader.validate(manifest, packageRoot: packageRoot)

    XCTAssertTrue(missingIssues.contains { $0.code == "MISSING_WORKFLOW_BUNDLE" && $0.path == "workflowDirectory" })

    try Data(#"{"nodes":[]}"#.utf8).write(to: workflowDirectory.appendingPathComponent("workflow.json", isDirectory: false))
    let presentIssues = await loader.validate(manifest, packageRoot: packageRoot)

    XCTAssertFalse(presentIssues.contains { $0.code == "MISSING_WORKFLOW_BUNDLE" })
  }

  func testLoaderRejectsNonFileManifestURLsBeforeReading() async {
    let loader = FileWorkflowPackageManifestLoader()
    let url = URL(string: "https://example.invalid/riela-package.json")!

    do {
      _ = try await loader.loadManifest(from: url)
      XCTFail("expected non-file URL rejection")
    } catch WorkflowPackageManifestLoadingError.nonFileURL(let value) {
      XCTAssertEqual(value, "https://example.invalid/riela-package.json")
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testRelativePathNormalizerFailsClosed() {
    XCTAssertEqual(WorkflowPackageManifestValidator.normalizePackageRelativePath("."), ".")
    XCTAssertEqual(WorkflowPackageManifestValidator.normalizePackageRelativePath("a/./b"), "a/b")
    XCTAssertNil(WorkflowPackageManifestValidator.normalizePackageRelativePath(""))
    XCTAssertNil(WorkflowPackageManifestValidator.normalizePackageRelativePath("a/.."))
    XCTAssertNil(WorkflowPackageManifestValidator.normalizePackageRelativePath("a/../b"))
    XCTAssertNil(WorkflowPackageManifestValidator.normalizePackageRelativePath("../secret"))
    XCTAssertNil(WorkflowPackageManifestValidator.normalizePackageRelativePath("/tmp/package"))
    XCTAssertNil(WorkflowPackageManifestValidator.normalizePackageRelativePath("C:\\temp\\package"))
    XCTAssertNil(WorkflowPackageManifestValidator.normalizePackageRelativePath("\\\\server\\share"))
  }

  func testManifestValidationRejectsWindowsAbsoluteDirectories() {
    let manifest = WorkflowPackageManifest(
      name: "workflow-package",
      version: "1.0.0",
      description: "Workflow package",
      tags: [],
      registry: "default",
      checksum: "abc123",
      checksumAlgorithm: "md5",
      workflowDirectory: "C:\\temp\\package",
      skillDirectory: "\\\\server\\share"
    )

    let issues = WorkflowPackageManifestValidator.validate(manifest)

    XCTAssertTrue(issues.contains { $0.path == "workflowDirectory" })
    XCTAssertTrue(issues.contains { $0.path == "skillDirectory" })
  }

  func testLoopPromotionMetadataValidatesRequiredFieldsAndPaths() {
    let missingRequired = WorkflowPackageManifest(
      name: "workflow-package",
      version: "1.0.0",
      description: "Workflow package",
      tags: [],
      registry: "default",
      checksum: "abc123",
      checksumAlgorithm: "md5",
      loop: WorkflowPackageLoopMetadata(promotionReady: true)
    )
    let unsafePaths = WorkflowPackageManifest(
      name: "workflow-package",
      version: "1.0.0",
      description: "Workflow package",
      tags: [],
      registry: "default",
      checksum: "abc123",
      checksumAlgorithm: "md5",
      loop: WorkflowPackageLoopMetadata(
        promotionReady: false,
        requiredMockScenarios: ["../mock.json", "."],
        expectedResults: ["/tmp/EXPECTED_RESULTS.md"],
        requiredGates: [""],
        requiredPolicies: [" "],
        minimumEvidenceSchemaVersion: 0
      )
    )

    let missingIssues = WorkflowPackageManifestValidator.validate(missingRequired)
    XCTAssertTrue(missingIssues.contains { $0.path == "loop.usageContract" })
    XCTAssertTrue(missingIssues.contains { $0.path == "loop.requiredMockScenarios" })
    XCTAssertTrue(missingIssues.contains { $0.path == "loop.expectedResults" })
    XCTAssertTrue(missingIssues.contains { $0.path == "loop.requiredGates" })
    XCTAssertTrue(missingIssues.contains { $0.path == "loop.requiredPolicies" })
    XCTAssertTrue(missingIssues.contains { $0.path == "loop.minimumEvidenceSchemaVersion" })

    let unsafeIssues = WorkflowPackageManifestValidator.validate(unsafePaths)
    XCTAssertTrue(unsafeIssues.contains { $0.path == "loop.requiredMockScenarios[0]" })
    XCTAssertTrue(unsafeIssues.contains { $0.path == "loop.requiredMockScenarios[1]" })
    XCTAssertTrue(unsafeIssues.contains { $0.path == "loop.expectedResults[0]" })
    XCTAssertTrue(unsafeIssues.contains { $0.path == "loop.requiredGates[0]" })
    XCTAssertTrue(unsafeIssues.contains { $0.path == "loop.requiredPolicies[0]" })
    XCTAssertTrue(unsafeIssues.contains { $0.path == "loop.minimumEvidenceSchemaVersion" })
  }

  func testLoaderValidationRequiresPromotionArtifactsWhenPromotionReady() async throws {
    let packageRoot = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: packageRoot) }
    try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
    try Data(#"{"nodes":[]}"#.utf8).write(to: packageRoot.appendingPathComponent("workflow.json"))
    let manifest = WorkflowPackageManifest(
      name: "workflow-package",
      version: "1.0.0",
      description: "Workflow package",
      tags: [],
      registry: "default",
      checksum: "abc123",
      checksumAlgorithm: "md5",
      loop: WorkflowPackageLoopMetadata(
        promotionReady: true,
        usageContract: true,
        requiredMockScenarios: ["mock-scenarios/review.json"],
        expectedResults: ["EXPECTED_RESULTS.md"],
        requiredGates: ["implementation-review"],
        requiredPolicies: ["runtime-owned-evidence"],
        minimumEvidenceSchemaVersion: 1
      )
    )
    let loader = FileWorkflowPackageManifestLoader()

    let missingIssues = await loader.validate(manifest, packageRoot: packageRoot)

    XCTAssertTrue(missingIssues.contains {
      $0.code == "MISSING_PROMOTION_ARTIFACT" && $0.path == "loop.requiredMockScenarios[0]"
    })
    XCTAssertTrue(missingIssues.contains {
      $0.code == "MISSING_PROMOTION_ARTIFACT" && $0.path == "loop.expectedResults[0]"
    })

    let mockRoot = packageRoot.appendingPathComponent("mock-scenarios", isDirectory: true)
    try FileManager.default.createDirectory(at: mockRoot, withIntermediateDirectories: true)
    try Data(#"{"messages":[]}"#.utf8).write(to: mockRoot.appendingPathComponent("review.json"))
    try Data("expected results\n".utf8).write(to: packageRoot.appendingPathComponent("EXPECTED_RESULTS.md"))

    let presentIssues = await loader.validate(manifest, packageRoot: packageRoot)

    XCTAssertFalse(presentIssues.contains { $0.code == "MISSING_PROMOTION_ARTIFACT" })
  }

  private func validManifest(nodeAddons: [WorkflowPackageNodeAddon]) -> WorkflowPackageManifest {
    WorkflowPackageManifest(
      name: "workflow-package",
      version: "1.0.0",
      description: "Workflow package",
      registry: "default",
      checksum: "abc123",
      checksumAlgorithm: "md5",
      nodeAddons: nodeAddons
    )
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  }
}
