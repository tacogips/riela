import Foundation
import XCTest
@testable import RielaCore

final class SwiftPackagingReadinessTests: XCTestCase {
  func testArchivePlanUsesReadinessOnlyNamesAndStagingPaths() {
    let plan = makeSwiftHomebrewReadinessArchivePlan(
      version: "0.1.15",
      target: .darwinArm64
    )

    XCTAssertEqual(plan.executableProduct, "riela")
    XCTAssertEqual(
      plan.releaseBinPathCommand,
      swiftHomebrewReadinessReleaseBinPathCommand
    )
    XCTAssertEqual(
      plan.stagedBinaryPath,
      "dist/swift-homebrew/work/riela-0.1.15-darwin-arm64/bin/riela"
    )
    XCTAssertEqual(
      plan.archivePath,
      "dist/swift-homebrew/riela-swift-0.1.15-darwin-arm64.tar.gz"
    )
    XCTAssertEqual(
      plan.checksumPath,
      "dist/swift-homebrew/riela-swift-0.1.15-darwin-arm64.tar.gz.sha256"
    )
    XCTAssertFalse(plan.publishSideEffects)
    XCTAssertFalse(plan.archivePath.contains("dist/homebrew/riela-0.1.15"))
  }

  func testSupportedTargetsAreMacOSOnlyBeforeCutover() {
    XCTAssertEqual(
      SwiftHomebrewReadinessTarget.allCases.map(\.rawValue),
      ["darwin-arm64", "darwin-x64"]
    )
  }

  func testProductionArchivePlanUsesHomebrewNamesAndStagingPaths() {
    let arm64 = makeSwiftHomebrewProductionArchivePlan(
      version: "0.1.15",
      target: .darwinArm64
    )
    let x64 = makeSwiftHomebrewProductionArchivePlan(
      version: "0.1.15",
      target: .darwinX64
    )
    let linuxX64 = makeSwiftHomebrewProductionArchivePlan(
      version: "0.1.15",
      target: .linuxX64
    )

    XCTAssertEqual(arm64.executableProduct, "riela")
    XCTAssertEqual(arm64.releaseDirectory, "dist/homebrew")
    XCTAssertEqual(arm64.target.triple, "arm64-apple-macosx")
    XCTAssertEqual(x64.target.triple, "x86_64-apple-macosx")
    XCTAssertEqual(linuxX64.target.triple, "x86_64-unknown-linux-gnu")
    XCTAssertEqual(
      arm64.stagedBinaryPath,
      "dist/homebrew/work/riela-0.1.15-darwin-arm64/bin/riela"
    )
    XCTAssertEqual(
      arm64.archivePath,
      "dist/homebrew/riela-0.1.15-darwin-arm64.tar.gz"
    )
    XCTAssertEqual(
      arm64.checksumPath,
      "dist/homebrew/riela-0.1.15-darwin-arm64.tar.gz.sha256"
    )
    XCTAssertEqual(
      x64.archivePath,
      "dist/homebrew/riela-0.1.15-darwin-x64.tar.gz"
    )
    XCTAssertEqual(
      linuxX64.archivePath,
      "dist/homebrew/riela-0.1.15-linux-x64.tar.gz"
    )
    XCTAssertFalse(arm64.archivePath.contains("riela-swift-"))
    XCTAssertFalse(arm64.publishSideEffects)
    XCTAssertFalse(x64.publishSideEffects)
    XCTAssertFalse(linuxX64.publishSideEffects)
  }

  func testSupportedProductionTargetsIncludeLinuxCLIOnlyArchives() {
    XCTAssertEqual(
      SwiftHomebrewProductionTarget.allCases.map(\.rawValue),
      ["darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64"]
    )
  }

  func testCaskArchivePlanUsesSignedDmgNamesAndHomebrewPrefixes() {
    let arm64 = makeSwiftHomebrewCaskArchivePlan(
      version: "0.1.15",
      target: .darwinArm64
    )
    let x64 = makeSwiftHomebrewCaskArchivePlan(
      version: "0.1.15",
      target: .darwinX64
    )

    XCTAssertEqual(arm64.executableProduct, "riela")
    XCTAssertEqual(arm64.appProduct, "RielaApp")
    XCTAssertEqual(arm64.releaseDirectory, "dist/homebrew-cask")
    XCTAssertEqual(arm64.target.triple, "arm64-apple-macosx")
    XCTAssertEqual(x64.target.triple, "x86_64-apple-macosx")
    XCTAssertEqual(arm64.installPrefix, "/opt/homebrew")
    XCTAssertEqual(x64.installPrefix, "/usr/local")
    XCTAssertEqual(
      arm64.stagedBinaryPath,
      "dist/homebrew-cask/work/riela-0.1.15-darwin-arm64/riela"
    )
    XCTAssertEqual(
      arm64.stagedAppBundlePath,
      "dist/homebrew-cask/work/riela-0.1.15-darwin-arm64/RielaApp.app"
    )
    XCTAssertEqual(
      x64.stagedBinaryPath,
      "dist/homebrew-cask/work/riela-0.1.15-darwin-x64/riela"
    )
    XCTAssertEqual(
      arm64.dmgPath,
      "dist/homebrew-cask/riela-0.1.15-darwin-arm64.dmg"
    )
    XCTAssertEqual(
      arm64.checksumPath,
      "dist/homebrew-cask/riela-0.1.15-darwin-arm64.dmg.sha256"
    )
    XCTAssertTrue(arm64.requiresAppleCredentials)
    XCTAssertFalse(arm64.publishSideEffects)
  }

  func testSupportedCaskTargetsAreMacOSOnly() {
    XCTAssertEqual(
      SwiftHomebrewCaskTarget.allCases.map(\.rawValue),
      ["darwin-arm64", "darwin-x64"]
    )
  }

  func testCutoverGateManifestRecordsProductionCutover() throws {
    let rootURL = try repositoryRoot()
    let manifestURL = rootURL.appendingPathComponent("packaging/homebrew/swift-cutover-gates.json")
    let data = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(SwiftCutoverGateManifest.self, from: data)

    XCTAssertEqual(manifest.productionRuntime, "swift-native")
    XCTAssertEqual(manifest.swiftArtifactStatus, "production-cutover-enabled")
    XCTAssertEqual(manifest.homebrewFormulaSource, "swift-executable-archive")
    XCTAssertEqual(manifest.swiftReadinessArchiveDirectory, "dist/swift-homebrew")
    XCTAssertEqual(manifest.currentProductionArchiveDirectory, "dist/homebrew")
    XCTAssertEqual(
      manifest.swiftArchiveNames,
      [
        "riela-swift-<version>-darwin-arm64.tar.gz",
        "riela-swift-<version>-darwin-x64.tar.gz"
      ]
    )
    XCTAssertTrue(manifest.allowsProductionCutover)
    XCTAssertEqual(manifest.typeScriptDeletionReadiness?.ready, true)
    XCTAssertEqual(
      manifest.typeScriptDeletionReadiness?.gatePath,
      "packaging/swift-deletion-readiness.json"
    )
    XCTAssertTrue(manifest.gates.count >= 10)
    XCTAssertTrue(manifest.gates.allSatisfy { $0.status == "passed" })
    XCTAssertEqual(manifest.gates.filter { $0.id == "task009-adversarial-review" }.map(\.status), ["passed"])
    XCTAssertTrue(manifest.gates.allSatisfy(\.requiredBeforeCutover))
    XCTAssertTrue(manifest.gates.allSatisfy(\.forbidsProductionMutation))
    XCTAssertEqual(manifest.productionCutoverEvidence?.intendedProductionRuntime, "swift-native")
    XCTAssertEqual(manifest.productionCutoverEvidence?.intendedHomebrewFormulaSource, "swift-executable-archive")
    XCTAssertEqual(manifest.productionCutoverEvidence?.productionArchiveDirectory, "dist/homebrew")
  }

  func testReadinessScriptDoesNotExecuteProductionPublishingCommands() throws {
    let rootURL = try repositoryRoot()
    let scriptURL = rootURL.appendingPathComponent("scripts/build-swift-homebrew-readiness.sh")
    let script = try String(contentsOf: scriptURL, encoding: .utf8)

    XCTAssertTrue(script.contains("--dry-run"))
    XCTAssertTrue(script.contains("RIELA_SWIFT_RELEASE_DIR"))
    XCTAssertTrue(script.contains("riela-swift-$version-$target.tar.gz"))
    XCTAssertFalse(script.contains("gh release"))
    XCTAssertFalse(script.contains("git push"))
    XCTAssertFalse(script.contains("brew tap"))
    XCTAssertFalse(script.contains("render-homebrew-formula"))
    XCTAssertFalse(script.contains("Formula/riela.rb"))
  }

  func testReadinessScriptWritesPortableChecksumSidecars() throws {
    let rootURL = try repositoryRoot()
    let scriptURL = rootURL.appendingPathComponent("scripts/build-swift-homebrew-readiness.sh")
    let script = try String(contentsOf: scriptURL, encoding: .utf8)

    XCTAssertTrue(script.contains("base=\"$(basename \"$file\")\""))
    XCTAssertTrue(script.contains("shasum -a 256 \"$base\""))
    XCTAssertTrue(script.contains("sha256sum \"$base\""))
    XCTAssertFalse(script.contains("shasum -a 256 \"$file\""))
    XCTAssertFalse(script.contains("sha256sum \"$file\""))
  }

  func testReadinessScriptRejectsUnsafeVersionBeforePrintingPaths() throws {
    let rootURL = try repositoryRoot()
    let result = try runReadinessScript(
      rootURL: rootURL,
      environment: ["RIELA_VERSION": "x/../../../escape"],
      arguments: ["--dry-run", "darwin-arm64"]
    )

    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssertTrue(result.stderr.contains("unsafe Swift readiness version"))
    XCTAssertFalse(result.stdout.contains("riela-x/../../../escape"))
  }

  func testReadinessScriptRejectsReleaseDirectoryTraversal() throws {
    let rootURL = try repositoryRoot()
    let result = try runReadinessScript(
      rootURL: rootURL,
      environment: [
        "RIELA_VERSION": "0.0.0-task008",
        "RIELA_SWIFT_RELEASE_DIR": "../escape"
      ],
      arguments: ["--dry-run", "darwin-arm64"]
    )

    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssertTrue(result.stderr.contains("unsafe Swift readiness release directory"))
  }

  func testProductionBuilderUsesSwiftAndSupportsLinuxCliTargets() throws {
    let rootURL = try repositoryRoot()
    let scriptURL = rootURL.appendingPathComponent("scripts/build-homebrew-release.sh")
    let script = try String(contentsOf: scriptURL, encoding: .utf8)

    XCTAssertTrue(script.contains("--dry-run"))
    XCTAssertTrue(script.contains("build -c release --product riela"))
    XCTAssertTrue(script.contains("--triple"))
    XCTAssertTrue(script.contains("linux-arm64"))
    XCTAssertTrue(script.contains("linux-x64"))
    XCTAssertTrue(script.contains("riela-$version-$target.tar.gz"))
    XCTAssertFalse(script.contains("bun build"))
    XCTAssertFalse(script.contains("--target \"bun-$target\""))
    XCTAssertFalse(script.contains("gh release"))
    XCTAssertFalse(script.contains("git push"))
    XCTAssertFalse(script.contains("brew tap"))

    let result = try runProductionBuilder(
      rootURL: rootURL,
      environment: ["RIELA_VERSION": "0.0.0-cutover"],
      arguments: ["--dry-run", "linux-x64"]
    )
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("target: linux-x64"))
    XCTAssertTrue(result.stdout.contains("swift triple: x86_64-unknown-linux-gnu"))
    XCTAssertTrue(result.stdout.contains("staged binary:"))
    XCTAssertFalse(result.stdout.contains("RielaApp.app"))
  }

  func testProductionBuilderWritesPortableChecksumSidecars() throws {
    let rootURL = try repositoryRoot()
    let scriptURL = rootURL.appendingPathComponent("scripts/build-homebrew-release.sh")
    let script = try String(contentsOf: scriptURL, encoding: .utf8)

    XCTAssertTrue(script.contains("base=\"$(basename \"$file\")\""))
    XCTAssertTrue(script.contains("shasum -a 256 \"$base\""))
    XCTAssertTrue(script.contains("sha256sum \"$base\""))
    XCTAssertFalse(script.contains("shasum -a 256 \"$file\""))
    XCTAssertFalse(script.contains("sha256sum \"$file\""))
  }

  func testCaskBuilderRequiresAppleCredentialsAndNotarizesDmg() throws {
    let rootURL = try repositoryRoot()
    let scriptURL = rootURL.appendingPathComponent("scripts/build-homebrew-cask-release.sh")
    let script = try String(contentsOf: scriptURL, encoding: .utf8)

    XCTAssertTrue(script.contains("--dry-run"))
    XCTAssertTrue(script.contains("APPLE_SIGNING_IDENTITY"))
    XCTAssertTrue(script.contains("APPLE_ID"))
    XCTAssertTrue(script.contains("APPLE_PASSWORD"))
    XCTAssertTrue(script.contains("APPLE_TEAM_ID"))
    XCTAssertTrue(script.contains("RIELA_APP_BUNDLE_ID"))
    XCTAssertTrue(script.contains("validate_bundle_id"))
    XCTAssertTrue(script.contains("write_riela_app_bundle"))
    XCTAssertTrue(script.contains("img/riela_icon.png"))
    XCTAssertTrue(script.contains("app_icon_name=\"RielaAppIcon\""))
    XCTAssertTrue(script.contains("${icon_name}.icns"))
    XCTAssertTrue(script.contains("<key>CFBundleIconFile</key>"))
    XCTAssertTrue(script.contains("iconutil -c icns"))
    XCTAssertTrue(script.contains("codesign --force --options runtime --timestamp"))
    XCTAssertTrue(script.contains("codesign --verify --deep --strict --verbose=2 \"$staged_app\""))
    XCTAssertTrue(script.contains("hdiutil create"))
    XCTAssertTrue(script.contains("notarytool\" submit"))
    XCTAssertTrue(script.contains("stapler\" staple"))
    XCTAssertTrue(script.contains("stapler\" validate"))
    XCTAssertTrue(script.contains("spctl --assess --type open"))
    XCTAssertFalse(script.contains("APPLE_INSTALLER_SIGNING_IDENTITY"))
    XCTAssertFalse(script.contains("productbuild"))
    XCTAssertFalse(script.contains("pkgbuild"))
    XCTAssertFalse(script.contains("gh release"))
    XCTAssertFalse(script.contains("git push"))
    XCTAssertFalse(script.contains("brew tap"))
  }

  func testMenuBarAppBuilderUsesRepositoryIconAsset() throws {
    let rootURL = try repositoryRoot()
    let scriptURL = rootURL.appendingPathComponent("scripts/build-riela-menu-bar-app.sh")
    let script = try String(contentsOf: scriptURL, encoding: .utf8)

    XCTAssertTrue(script.contains("img/riela_icon.png"))
    XCTAssertTrue(script.contains("app_icon_name=\"RielaAppIcon\""))
    XCTAssertTrue(script.contains("${icon_name}.icns"))
    XCTAssertTrue(script.contains("<key>CFBundleIconFile</key>"))
    XCTAssertTrue(script.contains("iconutil -c icns"))
  }

  func testCaskBuilderDryRunRejectsUnsafeInputs() throws {
    let rootURL = try repositoryRoot()
    let result = try runCaskBuilder(
      rootURL: rootURL,
      environment: ["RIELA_VERSION": "x/../../../escape"],
      arguments: ["--dry-run", "darwin-arm64"]
    )

    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssertTrue(result.stderr.contains("unsafe Swift cask version"))
    XCTAssertFalse(result.stdout.contains("riela-x/../../../escape"))

    let bundleResult = try runCaskBuilder(
      rootURL: rootURL,
      environment: [
        "RIELA_VERSION": "0.1.15",
        "RIELA_APP_BUNDLE_ID": "bad/bundle"
      ],
      arguments: ["--dry-run", "darwin-arm64"]
    )
    XCTAssertNotEqual(bundleResult.exitCode, 0)
    XCTAssertTrue(bundleResult.stderr.contains("unsafe RielaApp bundle identifier"))
  }

  func testCaskRendererUsesAppAndBinaryDmgCaskAndMacOSChecksums() throws {
    let rootURL = try repositoryRoot()
    let scriptURL = rootURL.appendingPathComponent("scripts/render-homebrew-cask.sh")
    let script = try String(contentsOf: scriptURL, encoding: .utf8)

    XCTAssertTrue(script.contains("darwin-arm64"))
    XCTAssertTrue(script.contains("darwin-x64"))
    XCTAssertTrue(script.contains("Casks/riela.rb"))
    XCTAssertTrue(script.contains("cask \"riela\" do"))
    XCTAssertTrue(script.contains("arch arm: \"darwin-arm64\", intel: \"darwin-x64\""))
    XCTAssertTrue(script.contains("sha256 arm:"))
    XCTAssertTrue(script.contains("riela-#{version}-#{arch}.dmg"))
    XCTAssertTrue(script.contains("app \"RielaApp.app\""))
    XCTAssertTrue(script.contains("binary \"riela\""))
    XCTAssertFalse(script.contains("uninstall pkgutil"))
    XCTAssertFalse(script.contains("riela-$version-linux"))
  }

  func testFormulaRendererRequiresMacOSCliChecksumsOnly() throws {
    let rootURL = try repositoryRoot()
    let scriptURL = rootURL.appendingPathComponent("scripts/render-homebrew-formula.sh")
    let script = try String(contentsOf: scriptURL, encoding: .utf8)

    XCTAssertTrue(script.contains("darwin-arm64"))
    XCTAssertTrue(script.contains("darwin-x64"))
    XCTAssertFalse(script.contains("linux-arm64"))
    XCTAssertFalse(script.contains("linux-x64"))
    XCTAssertFalse(script.contains("linux_arm64_sha"))
    XCTAssertFalse(script.contains("linux_x64_sha"))
    XCTAssertFalse(script.contains("riela-$version-linux"))
    XCTAssertTrue(script.contains("Swift-native workflow runtime"))
    XCTAssertTrue(script.contains("This renderer expects macOS Swift CLI production archives."))
    XCTAssertTrue(script.contains("Linux CLI archives"))
  }

  private struct SwiftCutoverGateManifest: Decodable {
    var productionRuntime: String
    var swiftArtifactStatus: String
    var homebrewFormulaSource: String
    var currentProductionArchiveDirectory: String
    var swiftReadinessArchiveDirectory: String
    var swiftArchiveNames: [String]
    var allowsProductionCutover: Bool
    var typeScriptDeletionReadiness: SwiftTypeScriptDeletionReadiness?
    var gates: [SwiftCutoverGate]
    var productionCutoverEvidence: SwiftProductionCutoverEvidence?
  }

  private struct SwiftTypeScriptDeletionReadiness: Decodable {
    var ready: Bool
    var gatePath: String
  }

  private struct SwiftCutoverGate: Decodable {
    var id: String
    var status: String
    var requiredBeforeCutover: Bool
    var forbidsProductionMutation: Bool
  }

  private struct SwiftProductionCutoverEvidence: Decodable {
    var intendedProductionRuntime: String
    var intendedHomebrewFormulaSource: String
    var productionArchiveDirectory: String
  }

  private struct ScriptResult {
    var exitCode: Int32
    var stdout: String
    var stderr: String
  }

  private func runReadinessScript(
    rootURL: URL,
    environment: [String: String],
    arguments: [String]
  ) throws -> ScriptResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [rootURL.appendingPathComponent("scripts/build-swift-homebrew-readiness.sh").path] + arguments
    process.currentDirectoryURL = rootURL
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    return ScriptResult(
      exitCode: process.terminationStatus,
      stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
      stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
  }

  private func runProductionBuilder(
    rootURL: URL,
    environment: [String: String],
    arguments: [String]
  ) throws -> ScriptResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [rootURL.appendingPathComponent("scripts/build-homebrew-release.sh").path] + arguments
    process.currentDirectoryURL = rootURL
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    return ScriptResult(
      exitCode: process.terminationStatus,
      stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
      stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
  }

  private func runCaskBuilder(
    rootURL: URL,
    environment: [String: String],
    arguments: [String]
  ) throws -> ScriptResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [rootURL.appendingPathComponent("scripts/build-homebrew-cask-release.sh").path] + arguments
    process.currentDirectoryURL = rootURL
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    return ScriptResult(
      exitCode: process.terminationStatus,
      stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
      stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
  }

  private func repositoryRoot() throws -> URL {
    var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    for _ in 0..<8 {
      if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
        return current
      }
      current.deleteLastPathComponent()
    }
    throw NSError(domain: "SwiftPackagingReadinessTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Package.swift not found"])
  }
}
