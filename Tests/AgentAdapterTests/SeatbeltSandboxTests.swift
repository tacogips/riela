import Foundation
import XCTest
@testable import ClaudeCodeAgent
@testable import CursorCLIAgent
@testable import RielaAdapters
@testable import RielaCore

final class SeatbeltSandboxTests: XCTestCase {
  private let unavailable = SeatbeltAvailability { false }
  private let available = SeatbeltAvailability { true }

  // MARK: - Settings parsing

  func testModeDefaultsToOffWhenUnset() throws {
    XCTAssertEqual(try SeatbeltSandboxSettings.mode(environment: [:]), .off)
    XCTAssertEqual(try SeatbeltSandboxSettings.mode(environment: ["RIELA_SANDBOX_SEATBELT": "   "]), .off)
  }

  func testModeParsesKnownValuesCaseInsensitively() throws {
    XCTAssertEqual(try SeatbeltSandboxSettings.mode(environment: ["RIELA_SANDBOX_SEATBELT": "off"]), .off)
    XCTAssertEqual(try SeatbeltSandboxSettings.mode(environment: ["RIELA_SANDBOX_SEATBELT": "AUTO"]), .auto)
    XCTAssertEqual(try SeatbeltSandboxSettings.mode(environment: ["RIELA_SANDBOX_SEATBELT": " Required "]), .required)
  }

  func testModeThrowsOnUnknownValue() {
    XCTAssertThrowsError(try SeatbeltSandboxSettings.mode(environment: ["RIELA_SANDBOX_SEATBELT": "loose"])) { error in
      guard let error = error as? AdapterExecutionError else {
        return XCTFail("expected AdapterExecutionError, got \(error)")
      }
      XCTAssertEqual(error.code, .policyBlocked)
    }
  }

  func testBuilderModePrefersBuilderEnvironmentThenProcessEnvironment() throws {
    XCTAssertEqual(
      try SeatbeltSandboxSettings.mode(
        builderEnvironment: ["RIELA_SANDBOX_SEATBELT": "auto"],
        processEnvironment: ["RIELA_SANDBOX_SEATBELT": "required"]
      ),
      .auto
    )
    XCTAssertEqual(
      try SeatbeltSandboxSettings.mode(
        builderEnvironment: [:],
        processEnvironment: ["RIELA_SANDBOX_SEATBELT": "required"]
      ),
      .required
    )
    XCTAssertEqual(
      try SeatbeltSandboxSettings.mode(builderEnvironment: [:], processEnvironment: [:]),
      .off
    )
  }

  // MARK: - Policy derivation

  func testDangerFullAccessAndAbsentModeYieldNoPolicy() {
    XCTAssertNil(
      localSandboxPolicy(
        for: .dangerFullAccess,
        workingDirectory: URL(fileURLWithPath: "/work"),
        artifactRoot: nil,
        enforcement: .auto
      )
    )
    XCTAssertNil(
      localSandboxPolicy(for: nil, workingDirectory: URL(fileURLWithPath: "/work"), artifactRoot: nil, enforcement: .auto)
    )
  }

  func testReadOnlyModeExposesOnlyStateRootsAsWritable() throws {
    let policy = try XCTUnwrap(
      localSandboxPolicy(
        for: .readOnly,
        workingDirectory: URL(fileURLWithPath: "/work"),
        artifactRoot: URL(fileURLWithPath: "/work/.riela/artifacts"),
        extraWritablePaths: ["~/.claude"],
        enforcement: .auto
      )
    )
    XCTAssertEqual(policy.writeScope, .paths(["~/.claude"]))
    XCTAssertTrue(policy.networkAllowed)
    XCTAssertNil(policy.readPaths)
  }

  func testReadOnlyModeWithoutStateRootsIsFullyReadOnly() throws {
    let policy = try XCTUnwrap(
      localSandboxPolicy(for: .readOnly, workingDirectory: nil, artifactRoot: nil, enforcement: .required)
    )
    XCTAssertEqual(policy.writeScope, .readOnly)
    XCTAssertEqual(policy.enforcement, .required)
  }

  func testWorkspaceWriteCollectsWorkingArtifactAndStateRoots() throws {
    let policy = try XCTUnwrap(
      localSandboxPolicy(
        for: .workspaceWrite,
        workingDirectory: URL(fileURLWithPath: "/work"),
        artifactRoot: URL(fileURLWithPath: "/artifacts"),
        extraWritablePaths: ["~/.cursor"],
        enforcement: .auto
      )
    )
    XCTAssertEqual(policy.writeScope, .paths(["/work", "/artifacts", "~/.cursor"]))
  }

  func testArtifactRootPrefersEnvironmentOverride() {
    XCTAssertEqual(
      seatbeltArtifactRoot(environment: ["RIELA_ARTIFACT_DIR": "/custom"], workingDirectory: URL(fileURLWithPath: "/work"))?.path,
      "/custom"
    )
    XCTAssertEqual(
      seatbeltArtifactRoot(environment: [:], workingDirectory: URL(fileURLWithPath: "/work"))?.path,
      "/work/.riela/artifacts"
    )
    XCTAssertNil(seatbeltArtifactRoot(environment: [:], workingDirectory: nil))
  }

  // MARK: - Profile generation

  func testReadOnlyProfileDeniesWritesAndAllowsBroadRead() throws {
    let profile = try seatbeltProfile(
      for: LocalProcessSandboxPolicy(writeScope: .readOnly, networkAllowed: true),
      workingDirectory: nil,
      temporaryDirectory: URL(fileURLWithPath: "/private/tmp")
    )
    XCTAssertTrue(profile.contains("(version 1)"))
    XCTAssertTrue(profile.contains("(deny default)"))
    XCTAssertTrue(profile.contains("(allow file-read*)"))
    XCTAssertTrue(profile.contains(#"(allow file-write-data (literal "/dev/null") (literal "/dev/dtracehelper"))"#))
    XCTAssertFalse(profile.contains("(allow file-write* (subpath"))
    XCTAssertTrue(profile.contains("(allow network*)"))
  }

  func testWorkspaceProfileEmitsSortedCanonicalizedWritableRoots() throws {
    let profile = try seatbeltProfile(
      for: LocalProcessSandboxPolicy(writeScope: .paths(["/work", "/artifacts"]), networkAllowed: false),
      workingDirectory: URL(fileURLWithPath: "/work"),
      temporaryDirectory: URL(fileURLWithPath: "/private/tmp")
    )
    let writableLines = profile
      .split(separator: "\n")
      .filter { $0.hasPrefix("(allow file-write* (subpath") }
      .map(String.init)
    XCTAssertEqual(
      writableLines,
      [
        #"(allow file-write* (subpath "/artifacts"))"#,
        #"(allow file-write* (subpath "/private/tmp"))"#,
        #"(allow file-write* (subpath "/work"))"#
      ]
    )
    XCTAssertTrue(profile.contains("(deny network*)"))
    XCTAssertFalse(profile.contains("(allow network*)"))
  }

  func testTemporaryDirectoryIsCanonicalizedIntoPrivateVar() throws {
    let profile = try seatbeltProfile(
      for: LocalProcessSandboxPolicy(writeScope: .paths(["/work"]), networkAllowed: true),
      workingDirectory: nil,
      temporaryDirectory: FileManager.default.temporaryDirectory
    )
    // macOS per-user temp lives under /var/folders which resolves physically to
    // /private/var/folders; the profile must use the /private form.
    #if os(macOS)
    XCTAssertTrue(profile.contains(#"(subpath "/private/var/folders"#), profile)
    XCTAssertFalse(profile.contains(#"(subpath "/var/folders"#), profile)
    #endif
    XCTAssertTrue(profile.contains(#"(subpath "/work")"#))
  }

  func testReadPathsNarrowingReplacesBroadReadAndIncludesWorkingDirectory() throws {
    let profile = try seatbeltProfile(
      for: LocalProcessSandboxPolicy(writeScope: .readOnly, readPaths: ["/allowed"], networkAllowed: true),
      workingDirectory: URL(fileURLWithPath: "/work"),
      temporaryDirectory: URL(fileURLWithPath: "/private/tmp")
    )
    XCTAssertFalse(profile.contains("(allow file-read*)\n"))
    XCTAssertTrue(profile.contains("(allow file-read-metadata)"))
    XCTAssertTrue(profile.contains(#"(allow file-read* (subpath "/allowed"))"#))
    XCTAssertTrue(profile.contains(#"(allow file-read* (subpath "/work"))"#))
  }

  func testProfileEscapesQuotesAndBackslashesInPaths() throws {
    let profile = try seatbeltProfile(
      for: LocalProcessSandboxPolicy(writeScope: .paths([#"/weird/"quote\slash"#]), networkAllowed: true),
      workingDirectory: nil,
      temporaryDirectory: URL(fileURLWithPath: "/private/tmp")
    )
    XCTAssertTrue(profile.contains(#"\"quote\\slash"#))
  }

  func testProfileRejectsControlCharactersInPaths() {
    XCTAssertThrowsError(
      try seatbeltProfile(
        for: LocalProcessSandboxPolicy(writeScope: .paths(["/work\nnewline"]), networkAllowed: true),
        workingDirectory: nil,
        temporaryDirectory: URL(fileURLWithPath: "/private/tmp")
      )
    ) { error in
      guard let error = error as? AdapterExecutionError else {
        return XCTFail("expected AdapterExecutionError, got \(error)")
      }
      XCTAssertEqual(error.code, .policyBlocked)
    }
  }

  // MARK: - Invocation rewrite

  func testInvocationReturnsNilWhenNoPolicy() throws {
    let configuration = LocalAgentProcessConfiguration(
      executableURL: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: ["claude", "-p"]
    )
    XCTAssertNil(try seatbeltInvocation(for: configuration, availability: available))
  }

  func testInvocationRewritesToSandboxExecPreservingArgvOrder() throws {
    var configuration = LocalAgentProcessConfiguration(
      executableURL: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: ["claude", "-p", "--model", "sonnet"],
      environment: ["A": "1"],
      unsetEnvironmentKeys: ["B"],
      workingDirectoryURL: URL(fileURLWithPath: "/work")
    )
    configuration.sandboxPolicy = LocalProcessSandboxPolicy(writeScope: .paths(["/work"]))

    let rewritten = try XCTUnwrap(
      seatbeltInvocation(for: configuration, availability: available, temporaryDirectory: URL(fileURLWithPath: "/private/tmp"))
    )
    XCTAssertEqual(rewritten.executableURL.path, "/usr/bin/sandbox-exec")
    XCTAssertEqual(rewritten.arguments[0], "-p")
    XCTAssertTrue(rewritten.arguments[1].contains("(version 1)"))
    XCTAssertEqual(Array(rewritten.arguments[2...]), ["/usr/bin/env", "claude", "-p", "--model", "sonnet"])
    XCTAssertEqual(rewritten.environment, ["A": "1"])
    XCTAssertEqual(rewritten.unsetEnvironmentKeys, ["B"])
    XCTAssertEqual(rewritten.workingDirectoryURL?.path, "/work")
    XCTAssertNil(rewritten.sandboxPolicy)
  }

  func testInvocationWithAutoEnforcementRunsPlainWhenUnavailable() throws {
    var configuration = LocalAgentProcessConfiguration(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["claude"])
    configuration.sandboxPolicy = LocalProcessSandboxPolicy(enforcement: .auto, writeScope: .readOnly)

    let result = try XCTUnwrap(seatbeltInvocation(for: configuration, availability: unavailable))
    XCTAssertEqual(result, configuration)
  }

  func testInvocationWithRequiredEnforcementThrowsWhenUnavailable() {
    var configuration = LocalAgentProcessConfiguration(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["claude"])
    configuration.sandboxPolicy = LocalProcessSandboxPolicy(enforcement: .required, writeScope: .readOnly)

    XCTAssertThrowsError(try seatbeltInvocation(for: configuration, availability: unavailable)) { error in
      guard let error = error as? AdapterExecutionError else {
        return XCTFail("expected AdapterExecutionError, got \(error)")
      }
      XCTAssertEqual(error.code, .policyBlocked)
    }
  }

  // MARK: - Integration (macOS + sandbox-exec only)

  #if os(macOS)
  func testReadOnlyPolicyDeniesWritesButKeepsStdout() async throws {
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SeatbeltAvailability.executablePath))
    let runner = FoundationLocalAgentProcessRunner()
    let target = FileManager.default.temporaryDirectory.appendingPathComponent("seatbelt-\(UUID().uuidString).txt")

    var configuration = LocalAgentProcessConfiguration(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "echo hello; touch \(target.path)"]
    )
    configuration.sandboxPolicy = LocalProcessSandboxPolicy(enforcement: .required, writeScope: .readOnly, networkAllowed: false)

    let result = try await runner.run(configuration: configuration, stdin: "", deadline: Date(timeIntervalSinceNow: 10))
    XCTAssertTrue(result.stdout.contains("hello"), result.stdout)
    XCTAssertNotEqual(result.terminationStatus, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
  }

  func testWorkspacePolicyAllowsWritesInsideRootButNotOutside() async throws {
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SeatbeltAvailability.executablePath))
    let runner = FoundationLocalAgentProcessRunner()
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("seatbelt-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let inside = workspace.appendingPathComponent("inside.txt")
    let outside = URL(fileURLWithPath: "/private/etc/seatbelt-should-not-exist-\(UUID().uuidString).txt")

    var insideConfiguration = LocalAgentProcessConfiguration(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "touch \(inside.path)"]
    )
    insideConfiguration.sandboxPolicy = LocalProcessSandboxPolicy(
      enforcement: .required,
      writeScope: .paths([workspace.path]),
      networkAllowed: false
    )
    let insideResult = try await runner.run(configuration: insideConfiguration, stdin: "", deadline: Date(timeIntervalSinceNow: 10))
    XCTAssertEqual(insideResult.terminationStatus, 0, insideResult.stderr)
    XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path))

    var outsideConfiguration = LocalAgentProcessConfiguration(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "touch \(outside.path)"]
    )
    outsideConfiguration.sandboxPolicy = LocalProcessSandboxPolicy(
      enforcement: .required,
      writeScope: .paths([workspace.path]),
      networkAllowed: false
    )
    let outsideResult = try await runner.run(configuration: outsideConfiguration, stdin: "", deadline: Date(timeIntervalSinceNow: 10))
    XCTAssertNotEqual(outsideResult.terminationStatus, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
  }
  #endif
}
