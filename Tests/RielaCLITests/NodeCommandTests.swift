import Foundation
import RielaAddons
import XCTest
@testable import RielaCLI

extension WorkflowCommandTests {
  func testNodeSearchInstallAndRunProvideAddonLevelWorkflowlessEntryPoint() async throws {
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-node-command")
    let registry = tempDir.appendingPathComponent("registry", isDirectory: true)
    let packageSource = registry.appendingPathComponent("packages/pdf-render-addon", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try installNodeAddonFixture(at: packageSource)

    let app = RielaCLIApplication()
    let install = await app.run([
      "node", "install", "tacogips/pdf-render",
      "--local-path", registry.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ], environment: ["HOME": tempDir.path, "PATH": ""])
    XCTAssertEqual(install.exitCode, .success, install.stderr)
    let installResult = try decodeJSON(WorkflowPackageCommandResult.self, from: install.stdout)
    XCTAssertEqual(installResult.packages.map(\.name), ["@tacogips/pdf-render-addon"])
    XCTAssertEqual(installResult.packages.first?.kind, .nodeAddon)
    XCTAssertEqual(installResult.packages.first?.addons?.map(\.name), ["tacogips/pdf-render"])
    XCTAssertTrue(installResult.message.contains("shared add-ons"), installResult.message)
    let sharedAddon = tempDir.appendingPathComponent(".riela/addons/tacogips/pdf-render/1", isDirectory: true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: sharedAddon.appendingPathComponent("addon.json").path))
    let sharedManifest = try decodeJSON(
      WorkflowPackageManifest.self,
      from: String(contentsOf: sharedAddon.appendingPathComponent("riela-package.json"))
    )
    XCTAssertEqual(sharedManifest.kind, .nodeAddon)
    XCTAssertEqual(sharedManifest.nodeAddons.map(\.name), ["tacogips/pdf-render"])
    XCTAssertEqual(sharedManifest.nodeAddons.map(\.sourcePath), ["."])

    let search = await app.run([
      "node", "search", "pdf-render",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(search.exitCode, .success, search.stderr)
    let searchResult = try decodeJSON(WorkflowPackageCommandResult.self, from: search.stdout)
    XCTAssertEqual(searchResult.scope, "node")
    XCTAssertEqual(searchResult.packages.map(\.name), ["@tacogips/pdf-render-addon"])
    XCTAssertEqual(searchResult.packages.first?.matchMetadata?.fields, ["package", "addons"])

    let list = await app.run([
      "node", "list",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(list.exitCode, .success, list.stderr)
    let listResult = try decodeJSON(WorkflowPackageCommandResult.self, from: list.stdout)
    XCTAssertEqual(listResult.scope, "node")
    XCTAssertEqual(listResult.command, "list")
    XCTAssertEqual(listResult.packages.map(\.name), ["@tacogips/pdf-render-addon"])
    XCTAssertNil(listResult.packages.first?.matchMetadata)

    let scenario = tempDir.appendingPathComponent("node-run-scenario.json")
    try """
    {
      "node-run": {
        "provider": "scenario-mock",
        "model": "node-runner",
        "payload": {"status": "ok", "pageCount": 2}
      }
    }
    """.write(to: scenario, atomically: true, encoding: .utf8)
    let run = await app.run([
      "node", "run", "tacogips/pdf-render",
      "--mock-scenario", scenario.path,
      "--variables", #"{"pdfPath":"/tmp/report.pdf"}"#,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .success, run.stderr)
    let runResult = try decodeJSON(NodeRunCommandResult.self, from: run.stdout)
    XCTAssertEqual(runResult.target, "tacogips/pdf-render")
    XCTAssertEqual(runResult.provider, "scenario-mock")
    XCTAssertEqual(runResult.payload["status"], .string("ok"))
    XCTAssertEqual(runResult.payload["pageCount"], .integer(2))

    let rrun = await app.run([
      "rrun", "tacogips/pdf-render",
      "--mock-scenario", scenario.path,
      "--variables", #"{"pdfPath":"/tmp/report.pdf"}"#,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(rrun.exitCode, .success, rrun.stderr)
    let rrunResult = try decodeJSON(NodeRunCommandResult.self, from: rrun.stdout)
    XCTAssertEqual(rrunResult.scope, "node")
    XCTAssertEqual(rrunResult.command, "run")
    XCTAssertEqual(rrunResult.target, "tacogips/pdf-render")
    XCTAssertEqual(rrunResult.provider, "scenario-mock")
    XCTAssertEqual(rrunResult.payload["status"], .string("ok"))
  }

  func testNodeRunPreflightsInstalledAddonRequiredEnvironment() async throws {
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-node-run-env-preflight")
    let registry = tempDir.appendingPathComponent("registry", isDirectory: true)
    let packageSource = registry.appendingPathComponent("packages/pdf-render-addon", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try installNodeAddonFixture(
      at: packageSource,
      requiredEnvironmentName: "RIELA_NODE_RUN_REQUIRED_TOKEN"
    )

    let app = RielaCLIApplication()
    let install = await app.run([
      "node", "install", "tacogips/pdf-render",
      "--local-path", registry.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ], environment: ["HOME": tempDir.path, "PATH": ""])
    XCTAssertEqual(install.exitCode, .success, install.stderr)

    let scenario = tempDir.appendingPathComponent("node-run-scenario.json")
    try """
    {
      "node-run": {
        "provider": "scenario-mock",
        "model": "node-runner",
        "payload": {"status": "ok"}
      }
    }
    """.write(to: scenario, atomically: true, encoding: .utf8)
    let mocked = await app.run([
      "node", "run", "tacogips/pdf-render",
      "--mock-scenario", scenario.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ], environment: ["HOME": tempDir.path, "PATH": ""])
    XCTAssertEqual(mocked.exitCode, .success, mocked.stderr)

    let run = await app.run([
      "node", "run", "tacogips/pdf-render",
      "--working-dir", tempDir.path,
      "--output", "json"
    ], environment: ["HOME": tempDir.path, "PATH": ""])
    XCTAssertEqual(run.exitCode, .failure)
    XCTAssertTrue(run.stdout.contains("node run preflight failed"), run.stdout)
    XCTAssertTrue(run.stdout.contains("missing required environment variables"), run.stdout)
    XCTAssertTrue(run.stdout.contains("RIELA_NODE_RUN_REQUIRED_TOKEN"), run.stdout)
    XCTAssertTrue(run.stdout.contains("@tacogips\\/pdf-render-addon"), run.stdout)
  }

  func testNodeInstallContainerAddonHintsSetupWhenRuntimeIsMissing() async throws {
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-node-install-container-hint")
    let packageSource = tempDir.appendingPathComponent("pdf-to-images-addon", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try installContainerNodeAddonFixture(at: packageSource)

    let install = await RielaCLIApplication().run([
      "node", "install", "tacogips/pdf-to-images",
      "--source", packageSource.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ], environment: ["HOME": tempDir.path, "PATH": ""])

    XCTAssertEqual(install.exitCode, .success, install.stderr + install.stdout)
    let result = try decodeJSON(WorkflowPackageCommandResult.self, from: install.stdout)
    XCTAssertTrue(result.message.contains("riela setup container --yes"), result.message)
    XCTAssertTrue(result.message.contains("RIELA_CONTAINER_RUNTIME"), result.message)
  }

  private func installNodeAddonFixture(
    at packageSource: URL,
    requiredEnvironmentName: String? = nil
  ) throws {
    let addonRoot = packageSource.appendingPathComponent("addons/tacogips/pdf-render/1", isDirectory: true)
    try FileManager.default.createDirectory(at: addonRoot, withIntermediateDirectories: true)
    try """
    {
      "name": "tacogips/pdf-render",
      "version": "1",
      "description": "Test add-on descriptor"
    }
    """.write(to: addonRoot.appendingPathComponent("addon.json"), atomically: true, encoding: .utf8)
    let checksum = try packageChecksum(packageRoot: packageSource)
    let environmentVariables = requiredEnvironmentName.map {
      """
      ,
        "environmentVariables": [
          {"name": "\($0)", "description": "Required token", "required": true, "secret": true}
        ]
      """
    } ?? ""
    try """
    {
      "name": "@tacogips/pdf-render-addon",
      "version": "1.0.0",
      "kind": "node-addon",
      "description": "PDF render add-on package",
      "tags": ["pdf", "node-addon"],
      "registry": "local",
      "checksum": "\(checksum)",
      "checksumAlgorithm": "md5"\(environmentVariables),
      "addons": [
        {
          "name": "tacogips/pdf-render",
          "version": "1",
          "sourcePath": "addons/tacogips/pdf-render/1",
          "execution": {"kind": "declarative"}
        }
      ]
    }
    """.write(to: packageSource.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
  }

  private func installContainerNodeAddonFixture(at packageSource: URL) throws {
    let addonRoot = packageSource.appendingPathComponent("addons/tacogips/pdf-to-images/1", isDirectory: true)
    try FileManager.default.createDirectory(at: addonRoot, withIntermediateDirectories: true)
    try "FROM scratch\n".write(to: addonRoot.appendingPathComponent("Containerfile"), atomically: true, encoding: .utf8)
    try """
    {
      "name": "tacogips/pdf-to-images",
      "version": "1",
      "description": "Container PDF renderer"
    }
    """.write(to: addonRoot.appendingPathComponent("addon.json"), atomically: true, encoding: .utf8)
    let checksum = try packageChecksum(packageRoot: packageSource)
    try """
    {
      "name": "@tacogips/pdf-to-images-addon",
      "version": "1.0.0",
      "kind": "node-addon",
      "description": "Container PDF render add-on package",
      "tags": ["pdf", "container"],
      "registry": "local",
      "checksum": "\(checksum)",
      "checksumAlgorithm": "md5",
      "addons": [
        {
          "name": "tacogips/pdf-to-images",
          "version": "1",
          "sourcePath": "addons/tacogips/pdf-to-images/1",
          "contentDigest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          "execution": {
            "kind": "container",
            "entrypoint": "pdf-to-images",
            "containerfilePath": "Containerfile"
          },
          "capabilities": [
            {"name": "container.run", "reason": "run the packaged renderer"},
            {"name": "filesystem.read", "scope": "addon.input", "reason": "read input PDFs"},
            {"name": "filesystem.write", "scope": "runtime.output", "reason": "write rendered images"}
          ]
        }
      ]
    }
    """.write(to: packageSource.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
  }
}
