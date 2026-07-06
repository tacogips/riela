import Foundation
import RielaAdapters
import RielaAddons
import RielaCore
import XCTest
@testable import RielaCLI

final class ContainerWorkflowAddonResolverTests: XCTestCase {
  func testContainerRuntimeDiscoveryPrefersAppleContainerThenDockerThenPodman() throws {
    let root = try makeRielaCLITestTemporaryDirectory("riela-container-runtime-discovery")
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try installExecutable(named: "docker", in: bin)
    try installExecutable(named: "podman", in: bin)

    var driver = ContainerRuntimeDiscovery(environment: ["PATH": bin.path]).selectedDriver()
    XCTAssertEqual(driver.kind, .docker)
    XCTAssertEqual(driver.executable, "docker")

    try installExecutable(named: "container", in: bin)
    driver = ContainerRuntimeDiscovery(environment: ["PATH": bin.path]).selectedDriver()
    XCTAssertEqual(driver.kind, .appleContainer)
    XCTAssertEqual(driver.executable, "container")
  }

  func testContainerRuntimeDiscoveryUsesConfiguredRuntimePath() throws {
    let driver = ContainerRuntimeDiscovery(
      environment: ["RIELA_CONTAINER_RUNTIME": "/opt/homebrew/bin/podman"]
    ).selectedDriver()

    XCTAssertEqual(driver.kind, .podman)
    XCTAssertEqual(driver.executable, "/opt/homebrew/bin/podman")
  }

  func testContainerAddonBuildsImageRunsContainerAndReturnsPayload() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("riela-container-addon")
    defer { try? FileManager.default.removeItem(at: root) }
    let addonRoot = root.appendingPathComponent("addons/tacogips/pdf-to-images/1", isDirectory: true)
    try FileManager.default.createDirectory(at: addonRoot, withIntermediateDirectories: true)
    try "FROM scratch\n".write(to: addonRoot.appendingPathComponent("Containerfile"), atomically: true, encoding: .utf8)

    let runner = RecordingContainerAddonProcessRunner { configuration, stdin in
      if configuration.arguments.contains("build") {
        XCTAssertEqual(configuration.executableURL.path, "/usr/bin/env")
        XCTAssertEqual(configuration.arguments.prefix(2), ["docker", "build"])
        XCTAssertTrue(configuration.arguments.contains(addonRoot.path))
        return LocalAgentProcessResult(stdout: "", stderr: "", terminationStatus: 0)
      }

      XCTAssertEqual(configuration.arguments.prefix(2), ["docker", "run"])
      XCTAssertTrue(configuration.arguments.contains("-i"))
      XCTAssertTrue(configuration.arguments.contains("--entrypoint"))
      XCTAssertTrue(configuration.arguments.contains("pdf-to-images"))
      XCTAssertTrue(configuration.arguments.contains("-w"))
      XCTAssertTrue(configuration.arguments.contains(root.path))
      XCTAssertTrue(configuration.arguments.contains { $0.contains("RIELA_ARTIFACT_DIR=") })
      XCTAssertTrue(configuration.arguments.contains("--read-only"))
      XCTAssertTrue(configuration.arguments.contains("--network"))
      XCTAssertTrue(configuration.arguments.contains("none"))
      XCTAssertTrue(configuration.arguments.contains { $0.contains("/input:/input:ro") })
      XCTAssertFalse(configuration.arguments.contains { $0.contains("PATH=") })
      let decoded = try decodeContainerAddonInput(stdin)
      XCTAssertEqual(decoded.addonName, "tacogips/pdf-to-images")
      XCTAssertEqual(decoded.nodePayload["inputs"], .object([
        "pdfPath": .string("/input/report.pdf")
      ]))
      XCTAssertEqual(decoded.nodePayload["config"], .object([
        "dpi": .integer(160),
        "format": .string("png")
      ]))
      return LocalAgentProcessResult(stdout: #"{"pageCount":2,"status":"ok"}"# + "\n", stderr: "", terminationStatus: 0)
    }

    let resolver = ContainerWorkflowAddonResolver(
      registrations: [
        ContainerAddonRegistration(
          packageName: "@tacogips/pdf-to-images-addon",
          addonName: "tacogips/pdf-to-images",
          version: "1",
          packageRoot: root,
          addonRoot: addonRoot,
          entrypoint: "pdf-to-images",
          containerfilePath: "addons/tacogips/pdf-to-images/1/Containerfile",
          image: nil,
          imageDigest: nil,
          contentDigest: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          capabilities: [
            .init(name: "container.run", reason: "render"),
            .init(name: "filesystem.read", scope: "/input", reason: "read input PDFs")
          ]
        )
      ],
      workingDirectory: root,
      environment: [
        "RIELA_CONTAINER_RUNTIME": "docker",
        "RIELA_ARTIFACT_DIR": root.appendingPathComponent("artifacts", isDirectory: true).path
      ],
      runner: runner
    )

    let output = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "pdf-analysis",
        stepId: "render",
        nodeId: "render",
        addon: WorkflowNodeAddonRef(
          name: "tacogips/pdf-to-images",
          version: "1",
          config: [
            "dpi": .integer(160),
            "format": .string("png")
          ],
          inputs: [
            "pdfPath": .string("{{input.pdfPath}}")
          ]
        ),
        resolvedInputPayload: ["pdfPath": .string("/input/report.pdf")]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.provider, "container-addon")
    XCTAssertEqual(output.model, "tacogips/pdf-to-images")
    XCTAssertEqual(output.payload["status"], .string("ok"))
    XCTAssertEqual(output.payload["pageCount"], .integer(2))
    let callCount = await runner.callCount()
    XCTAssertEqual(callCount, 2)
  }

  func testContainerAddonInputScopeMountsPayloadPathParentsAndRuntimeOutput() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("riela-container-addon-input-scope")
    defer { try? FileManager.default.removeItem(at: root) }
    let addonRoot = root.appendingPathComponent("addons/tacogips/pdf-to-images/1", isDirectory: true)
    let fixtures = root.appendingPathComponent("fixtures", isDirectory: true)
    let artifactRoot = root.appendingPathComponent("artifacts", isDirectory: true)
    try FileManager.default.createDirectory(at: addonRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)

    let runner = RecordingContainerAddonProcessRunner { configuration, stdin in
      XCTAssertEqual(configuration.arguments.prefix(2), ["docker", "run"])
      XCTAssertTrue(configuration.arguments.contains("-w"))
      XCTAssertTrue(configuration.arguments.contains(root.path))
      XCTAssertTrue(configuration.arguments.contains { $0 == "\(fixtures.path):\(fixtures.path):ro" })
      XCTAssertTrue(configuration.arguments.contains { $0 == "\(artifactRoot.path):\(artifactRoot.path)" })
      XCTAssertFalse(configuration.arguments.contains { $0.contains("addon.input") })
      XCTAssertFalse(configuration.arguments.contains { $0.contains("runtime.output") })
      let decoded = try decodeContainerAddonInput(stdin)
      XCTAssertEqual(decoded.nodePayload["inputs"], .object([
        "pdfPath": .string("fixtures/report.pdf"),
        "outputDirectory": .string("pages")
      ]))
      return LocalAgentProcessResult(stdout: #"{"status":"ok"}"# + "\n", stderr: "", terminationStatus: 0)
    }

    let resolver = ContainerWorkflowAddonResolver(
      registrations: [
        ContainerAddonRegistration(
          packageName: "@tacogips/pdf-to-images-addon",
          addonName: "tacogips/pdf-to-images",
          version: "1",
          packageRoot: root,
          addonRoot: addonRoot,
          entrypoint: "pdf-to-images",
          containerfilePath: nil,
          image: "ghcr.io/tacogips/pdf-to-images",
          imageDigest: "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
          contentDigest: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          capabilities: [
            .init(name: "container.run", reason: "render"),
            .init(name: "filesystem.read", scope: "addon.input", reason: "read input PDFs"),
            .init(name: "filesystem.write", scope: "runtime.output", reason: "write artifacts")
          ]
        )
      ],
      workingDirectory: root,
      environment: [
        "RIELA_CONTAINER_RUNTIME": "docker",
        "RIELA_ARTIFACT_DIR": artifactRoot.path
      ],
      runner: runner
    )

    let output = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "pdf-analysis",
        stepId: "render",
        nodeId: "render",
        addon: WorkflowNodeAddonRef(
          name: "tacogips/pdf-to-images",
          version: "1",
          inputs: [
            "pdfPath": .string("fixtures/report.pdf"),
            "outputDirectory": .string("pages")
          ]
        ),
        resolvedInputPayload: [:]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["status"], .string("ok"))
    let callCount = await runner.callCount()
    XCTAssertEqual(callCount, 1)
  }

  func testContainerAddonUsesPrebuiltImageWithoutBuild() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("riela-container-addon-image")
    defer { try? FileManager.default.removeItem(at: root) }
    let addonRoot = root.appendingPathComponent("addons/tacogips/pdf-to-images/1", isDirectory: true)
    try FileManager.default.createDirectory(at: addonRoot, withIntermediateDirectories: true)

    let digest = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    let runner = RecordingContainerAddonProcessRunner { configuration, stdin in
      XCTAssertEqual(configuration.arguments.prefix(2), ["docker", "run"])
      XCTAssertFalse(configuration.arguments.contains("build"))
      XCTAssertTrue(configuration.arguments.contains("ghcr.io/tacogips/pdf-to-images@\(digest)"))
      let decoded = try decodeContainerAddonInput(stdin)
      XCTAssertEqual(decoded.addonName, "tacogips/pdf-to-images")
      return LocalAgentProcessResult(stdout: #"{"status":"ok"}"# + "\n", stderr: "", terminationStatus: 0)
    }

    let resolver = ContainerWorkflowAddonResolver(
      registrations: [
        ContainerAddonRegistration(
          packageName: "@tacogips/pdf-to-images-addon",
          addonName: "tacogips/pdf-to-images",
          version: "1",
          packageRoot: root,
          addonRoot: addonRoot,
          entrypoint: nil,
          containerfilePath: nil,
          image: "ghcr.io/tacogips/pdf-to-images",
          imageDigest: digest,
          contentDigest: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          capabilities: [.init(name: "container.run", reason: "render")]
        )
      ],
      workingDirectory: root,
      environment: [
        "RIELA_CONTAINER_RUNTIME": "docker",
        "RIELA_ARTIFACT_DIR": root.appendingPathComponent("artifacts", isDirectory: true).path
      ],
      runner: runner
    )

    let output = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "pdf-analysis",
        stepId: "render",
        nodeId: "render",
        addon: WorkflowNodeAddonRef(
          name: "tacogips/pdf-to-images",
          version: "1"
        ),
        resolvedInputPayload: [:]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["status"], .string("ok"))
    let callCount = await runner.callCount()
    XCTAssertEqual(callCount, 1)
  }

  func testContainerAddonBuildsLocalFallbackWhenImageDigestIsNotPinned() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("riela-container-addon-image-unpinned")
    defer { try? FileManager.default.removeItem(at: root) }
    let addonRoot = root.appendingPathComponent("addons/tacogips/pdf-to-images/1", isDirectory: true)
    try FileManager.default.createDirectory(at: addonRoot, withIntermediateDirectories: true)
    try "FROM scratch\n".write(to: addonRoot.appendingPathComponent("Containerfile"), atomically: true, encoding: .utf8)

    let runner = RecordingContainerAddonProcessRunner { configuration, _ in
      if configuration.arguments.contains("build") {
        XCTAssertEqual(configuration.arguments.prefix(2), ["docker", "build"])
        XCTAssertTrue(configuration.arguments.contains(addonRoot.appendingPathComponent("Containerfile").path))
        return LocalAgentProcessResult(stdout: "", stderr: "", terminationStatus: 0)
      }
      XCTAssertEqual(configuration.arguments.prefix(2), ["docker", "run"])
      XCTAssertFalse(configuration.arguments.contains("ghcr.io/tacogips/pdf-to-images"))
      XCTAssertTrue(configuration.arguments.contains { $0.hasPrefix("riela-addon-tacogips-pdf-to-images-addon-tacogips-pdf-to-images:") })
      return LocalAgentProcessResult(stdout: #"{"status":"ok"}"# + "\n", stderr: "", terminationStatus: 0)
    }

    let resolver = ContainerWorkflowAddonResolver(
      registrations: [
        ContainerAddonRegistration(
          packageName: "@tacogips/pdf-to-images-addon",
          addonName: "tacogips/pdf-to-images",
          version: "1",
          packageRoot: root,
          addonRoot: addonRoot,
          entrypoint: nil,
          containerfilePath: "Containerfile",
          image: "ghcr.io/tacogips/pdf-to-images",
          imageDigest: nil,
          contentDigest: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          capabilities: [.init(name: "container.run", reason: "render")]
        )
      ],
      workingDirectory: root,
      environment: [
        "RIELA_CONTAINER_RUNTIME": "docker",
        "RIELA_ARTIFACT_DIR": root.appendingPathComponent("artifacts", isDirectory: true).path
      ],
      runner: runner
    )

    let output = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "pdf-analysis",
        stepId: "render",
        nodeId: "render",
        addon: WorkflowNodeAddonRef(
          name: "tacogips/pdf-to-images",
          version: "1"
        ),
        resolvedInputPayload: [:]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["status"], .string("ok"))
    let callCount = await runner.callCount()
    XCTAssertEqual(callCount, 2)
  }

  func testContainerAddonMapsDeclaredSandboxCapabilitiesToRuntimeArguments() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("riela-container-addon-sandbox-policy")
    defer { try? FileManager.default.removeItem(at: root) }
    let addonRoot = root.appendingPathComponent("addons/tacogips/downloader/1", isDirectory: true)
    try FileManager.default.createDirectory(at: addonRoot, withIntermediateDirectories: true)
    let downloads = root.appendingPathComponent("downloads", isDirectory: true)

    let runner = RecordingContainerAddonProcessRunner { configuration, stdin in
      XCTAssertEqual(configuration.arguments.prefix(2), ["docker", "run"])
      XCTAssertTrue(configuration.arguments.contains("--read-only"))
      XCTAssertTrue(configuration.arguments.contains { $0 == "\(downloads.path):\(downloads.path)" })
      XCTAssertFalse(configuration.arguments.contains("--network"))
      XCTAssertTrue(configuration.arguments.contains { $0 == "PATH=/host/bin" })
      XCTAssertFalse(configuration.arguments.contains { $0.contains("HOME=") })
      _ = try decodeContainerAddonInput(stdin)
      return LocalAgentProcessResult(stdout: #"{"status":"ok"}"# + "\n", stderr: "", terminationStatus: 0)
    }

    let resolver = ContainerWorkflowAddonResolver(
      registrations: [
        ContainerAddonRegistration(
          packageName: "@tacogips/downloader-addon",
          addonName: "tacogips/downloader",
          version: "1",
          packageRoot: root,
          addonRoot: addonRoot,
          entrypoint: nil,
          containerfilePath: nil,
          image: "ghcr.io/tacogips/downloader",
          imageDigest: "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
          contentDigest: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          capabilities: [
            .init(name: "container.run", reason: "download"),
            .init(name: "network.egress", reason: "fetch remote media"),
            .init(name: "filesystem.write", scope: "downloads", reason: "write downloaded media"),
            .init(name: "env.read", scope: "PATH", reason: "preserve tool path")
          ]
        )
      ],
      workingDirectory: root,
      environment: [
        "RIELA_CONTAINER_RUNTIME": "docker",
        "PATH": "/host/bin",
        "HOME": "/host/home"
      ],
      runner: runner
    )

    let output = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "download",
        stepId: "download",
        nodeId: "download",
        addon: WorkflowNodeAddonRef(name: "tacogips/downloader", version: "1"),
        resolvedInputPayload: ["outputDirectory": .string(downloads.path + "/")]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["status"], .string("ok"))
    let callCount = await runner.callCount()
    XCTAssertEqual(callCount, 1)
  }

  func testContainerAddonFailsBeforeProcessWhenRuntimeIsMissing() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("riela-container-addon-missing-runtime")
    defer { try? FileManager.default.removeItem(at: root) }
    let addonRoot = root.appendingPathComponent("addons/tacogips/pdf-to-images/1", isDirectory: true)
    try FileManager.default.createDirectory(at: addonRoot, withIntermediateDirectories: true)

    let runner = RecordingContainerAddonProcessRunner { _, _ in
      XCTFail("container runtime preflight should fail before spawning a process")
      return LocalAgentProcessResult(stdout: "", stderr: "", terminationStatus: 1)
    }
    let resolver = ContainerWorkflowAddonResolver(
      registrations: [
        ContainerAddonRegistration(
          packageName: "@tacogips/pdf-to-images-addon",
          addonName: "tacogips/pdf-to-images",
          version: "1",
          packageRoot: root,
          addonRoot: addonRoot,
          entrypoint: nil,
          containerfilePath: nil,
          image: "ghcr.io/tacogips/pdf-to-images",
          imageDigest: "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
          contentDigest: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          capabilities: [.init(name: "container.run", reason: "render")]
        )
      ],
      workingDirectory: root,
      environment: ["PATH": ""],
      runner: runner
    )

    do {
      _ = try await resolver.execute(
        WorkflowAddonExecutionInput(
          workflowId: "pdf-analysis",
          stepId: "render",
          nodeId: "render",
          addon: WorkflowNodeAddonRef(name: "tacogips/pdf-to-images", version: "1"),
          resolvedInputPayload: [:]
        ),
        context: AdapterExecutionContext()
      )
      XCTFail("expected missing container runtime error")
    } catch {
      XCTAssertTrue("\(error)".contains("riela setup container"), "\(error)")
    }
    let callCount = await runner.callCount()
    XCTAssertEqual(callCount, 0)
  }

  func testContainerAddonBlocksUndeclaredAbsoluteInputPathsBeforeProcess() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("riela-container-addon-policy-block")
    defer { try? FileManager.default.removeItem(at: root) }
    let addonRoot = root.appendingPathComponent("addons/tacogips/pdf-to-images/1", isDirectory: true)
    try FileManager.default.createDirectory(at: addonRoot, withIntermediateDirectories: true)

    let runner = RecordingContainerAddonProcessRunner { _, _ in
      XCTFail("filesystem capability preflight should fail before spawning a process")
      return LocalAgentProcessResult(stdout: "", stderr: "", terminationStatus: 1)
    }
    let resolver = ContainerWorkflowAddonResolver(
      registrations: [
        ContainerAddonRegistration(
          packageName: "@tacogips/pdf-to-images-addon",
          addonName: "tacogips/pdf-to-images",
          version: "1",
          packageRoot: root,
          addonRoot: addonRoot,
          entrypoint: nil,
          containerfilePath: nil,
          image: "ghcr.io/tacogips/pdf-to-images",
          imageDigest: "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
          contentDigest: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          capabilities: [.init(name: "container.run", reason: "render")]
        )
      ],
      workingDirectory: root,
      environment: ["RIELA_CONTAINER_RUNTIME": "docker"],
      runner: runner
    )

    do {
      _ = try await resolver.execute(
        WorkflowAddonExecutionInput(
          workflowId: "pdf-analysis",
          stepId: "render",
          nodeId: "render",
          addon: WorkflowNodeAddonRef(name: "tacogips/pdf-to-images", version: "1"),
          resolvedInputPayload: ["pdfPath": .string("/input/report.pdf")]
        ),
        context: AdapterExecutionContext()
      )
      XCTFail("expected undeclared filesystem capability error")
    } catch {
      XCTAssertTrue("\(error)".contains("filesystem capabilities"), "\(error)")
      XCTAssertTrue("\(error)".contains("/input/report.pdf"), "\(error)")
    }
    let callCount = await runner.callCount()
    XCTAssertEqual(callCount, 0)
  }

  func testInstalledContainerAddonRegistrationsReadProjectPackages() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("riela-installed-container-addon")
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent(".riela/packages/@tacogips/pdf-to-images-addon", isDirectory: true)
    let addonRoot = package.appendingPathComponent("addons/tacogips/pdf-to-images/1", isDirectory: true)
    try FileManager.default.createDirectory(at: addonRoot, withIntermediateDirectories: true)
    try "FROM scratch\n".write(to: addonRoot.appendingPathComponent("Containerfile"), atomically: true, encoding: .utf8)
    try """
    {
      "name": "@tacogips/pdf-to-images-addon",
      "version": "1.0.0",
      "kind": "node-addon",
      "description": "PDF renderer",
      "addons": [{
        "name": "tacogips/pdf-to-images",
        "version": "1",
        "sourcePath": "addons/tacogips/pdf-to-images/1",
        "contentDigest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "execution": {
          "kind": "container",
          "entrypoint": "pdf_to_images.py",
          "containerfilePath": "addons/tacogips/pdf-to-images/1/Containerfile",
          "image": "ghcr.io/tacogips/pdf-to-images",
          "imageDigest": "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        },
        "capabilities": [{"name": "container.run", "reason": "render", "defaultPolicy": "prompt"}]
      }]
    }
    """.write(to: package.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let registrations = try await installedContainerAddonRegistrations(workingDirectory: root)

    XCTAssertEqual(registrations.map(\.packageName), ["@tacogips/pdf-to-images-addon"])
    XCTAssertEqual(registrations.map(\.addonName), ["tacogips/pdf-to-images"])
    XCTAssertEqual(registrations.map(\.entrypoint), ["pdf_to_images.py"])
    XCTAssertEqual(registrations.map(\.containerfilePath), ["addons/tacogips/pdf-to-images/1/Containerfile"])
    XCTAssertEqual(registrations.map(\.image), ["ghcr.io/tacogips/pdf-to-images"])
    XCTAssertEqual(registrations.map(\.imageDigest), ["sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"])
    XCTAssertEqual(registrations.map(\.capabilities).flatMap { $0 }.map(\.name), ["container.run"])
  }

  func testInstalledContainerAddonRegistrationsReadLegacySharedAddonStore() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("riela-shared-container-addon")
    defer { try? FileManager.default.removeItem(at: root) }
    let sharedAddon = root.appendingPathComponent(".riela/content-ad/addons/tacogips/pdf-to-images/1", isDirectory: true)
    try FileManager.default.createDirectory(at: sharedAddon, withIntermediateDirectories: true)
    try "FROM scratch\n".write(to: sharedAddon.appendingPathComponent("Containerfile"), atomically: true, encoding: .utf8)
    try """
    {
      "name": "@tacogips/pdf-to-images-addon",
      "version": "1.0.0",
      "kind": "node-addon",
      "description": "PDF renderer legacy shared add-on",
      "addons": [{
        "name": "tacogips/pdf-to-images",
        "version": "1",
        "sourcePath": ".",
        "contentDigest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "execution": {
          "kind": "container",
          "entrypoint": "pdf_to_images.py",
          "containerfilePath": "Containerfile"
        },
        "capabilities": [{"name": "container.run", "reason": "render", "defaultPolicy": "prompt"}]
      }]
    }
    """.write(to: sharedAddon.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let registrations = try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": root.path]) {
      try await installedContainerAddonRegistrations(workingDirectory: root.appendingPathComponent("project", isDirectory: true))
    }

    XCTAssertEqual(registrations.map(\.packageName), ["@tacogips/pdf-to-images-addon"])
    XCTAssertEqual(registrations.map(\.addonName), ["tacogips/pdf-to-images"])
    XCTAssertEqual(registrations.map(\.addonRoot), [sharedAddon])
    XCTAssertEqual(registrations.map(\.containerfilePath), ["Containerfile"])
  }

  func testInstalledContainerAddonRegistrationsReadSharedAddonStore() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("riela-legacy-shared-container-addon")
    defer { try? FileManager.default.removeItem(at: root) }
    let sharedAddon = root.appendingPathComponent(".riela/addons/tacogips/pdf-to-images/1", isDirectory: true)
    try FileManager.default.createDirectory(at: sharedAddon, withIntermediateDirectories: true)
    try "FROM scratch\n".write(to: sharedAddon.appendingPathComponent("Containerfile"), atomically: true, encoding: .utf8)
    try """
    {
      "name": "@tacogips/pdf-to-images-addon",
      "version": "1.0.0",
      "kind": "node-addon",
      "description": "Shared add-on",
      "addons": [{
        "name": "tacogips/pdf-to-images",
        "version": "1",
        "sourcePath": ".",
        "contentDigest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "execution": {
          "kind": "container",
          "entrypoint": "pdf_to_images.py",
          "containerfilePath": "Containerfile"
        },
        "capabilities": [{"name": "container.run", "reason": "render", "defaultPolicy": "prompt"}]
      }]
    }
    """.write(to: sharedAddon.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let registrations = try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": root.path]) {
      try await installedContainerAddonRegistrations(workingDirectory: root.appendingPathComponent("project", isDirectory: true))
    }

    XCTAssertEqual(registrations.map(\.addonName), ["tacogips/pdf-to-images"])
    XCTAssertEqual(registrations.map(\.addonRoot), [sharedAddon])
  }

}

private func installExecutable(named name: String, in directory: URL) throws {
  let url = directory.appendingPathComponent(name)
  try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func decodeContainerAddonInput(_ stdin: String) throws -> AddonExecutionInput {
  let line = try XCTUnwrap(stdin.split(whereSeparator: \.isNewline).first)
  return try JSONDecoder().decode(AddonExecutionInput.self, from: Data(String(line).utf8))
}

private actor RecordingContainerAddonProcessRunner: LocalAgentProcessRunning {
  typealias Handler = @Sendable (LocalAgentProcessConfiguration, String) throws -> LocalAgentProcessResult

  private let handler: Handler
  private var count = 0

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date?
  ) async throws -> LocalAgentProcessResult {
    count += 1
    return try handler(configuration, stdin)
  }

  func callCount() -> Int {
    count
  }
}
