import Foundation
import XCTest

final class SourceDeletionReadinessTests: XCTestCase {
  private var temporaryDirectories: [URL] = []

  override func tearDownWithError() throws {
    for directory in temporaryDirectories {
      try? FileManager.default.removeItem(at: directory)
    }
    temporaryDirectories.removeAll()
    try super.tearDownWithError()
  }

  func testNoDeletionBlockingTypeScriptFamilyFilesRemain() throws {
    let files = try collectRepositoryFiles()
    let blocking = files.filter { file in
      let name = URL(fileURLWithPath: file).lastPathComponent
      return name.hasSuffix(".ts")
        || name.hasSuffix(".tsx")
        || name.hasSuffix(".mts")
        || name.hasSuffix(".cts")
        || name.hasSuffix(".mjs")
        || name.hasSuffix(".d.ts")
    }

    XCTAssertEqual(blocking, [], "TypeScript-family files must be removed or explicitly retained before deletion readiness")
  }

  func testBunTestWrapperIsNoOpAfterTypeScriptSourceDeletion() throws {
    let root = try repositoryRoot()
    let result = try runScript(root: root, relativePath: "scripts/run-bun-tests.sh")

    XCTAssertEqual(result.exitCode, 0, result.stderr)
    XCTAssertTrue(
      result.stdout.contains("No Bun TypeScript tests remain after TypeScript source deletion; skipping."),
      result.stdout
    )
  }

  func testRunnableExamplesDoNotReferenceDeletedTypeScriptCLIEntrypoint() throws {
    let root = try repositoryRoot()
    let files = try collectFiles(root: root, relativePath: "examples")
      .filter { [".json", ".md", ".sh"].contains(URL(fileURLWithPath: $0).pathExtensionWithDot) }
      .sorted()
    var violations: [String] = []

    for file in files {
      let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
      if text.contains("packages/riela/src/bin.ts") {
        violations.append(file)
      }
    }

    XCTAssertEqual(violations, [], "Runnable examples must use the Swift riela CLI after TypeScript source deletion")
  }

  func testSourceFilenamePolicyRemainsCoveredWithoutTypeScriptScript() throws {
    let root = try repositoryRoot()
    let result = try checkSourceFilenamePolicy(root: root)

    XCTAssertFalse(result.rootSourceTreePresent)
    XCTAssertEqual(result.violations, [], "Use descriptive split filenames instead of part-<digits>.ts or part-<digits>.tsx")
  }

  func testSourceFilenamePolicyMatchesDeletedFixtureMatrix() throws {
    let root = try makeTemporaryRepository()
    try writeFixture(root: root, relativePath: "vitest.config.ts")
    try writeFixture(root: root, relativePath: "packages/example/src/part-1.ts")
    try writeFixture(root: root, relativePath: "packages/example/src/nested/part-01.ts")
    try writeFixture(root: root, relativePath: "packages/example/src/components/part-1.tsx")
    try writeFixture(root: root, relativePath: "packages/example/src/components/part-01.tsx")
    try writeFixture(root: root, relativePath: "vitest-support/part-1.ts")
    try writeFixture(root: root, relativePath: "packages/example/src/workflow-loader.ts")
    try writeFixture(root: root, relativePath: "packages/example/src/node-output-contract.ts")
    try writeFixture(root: root, relativePath: "packages/example/src/session-partition.ts")
    try writeFixture(root: root, relativePath: "packages/example/src/feature-part-1.ts")
    try writeFixture(root: root, relativePath: "packages/example/src/part-1.test.ts")
    try writeFixture(root: root, relativePath: "docs/part-1.ts")

    let result = try checkSourceFilenamePolicy(root: root)

    XCTAssertFalse(result.rootSourceTreePresent)
    XCTAssertEqual(
      result.violations,
      [
        FilenamePolicyViolation(path: "packages/example/src/components/part-01.tsx", basename: "part-01.tsx"),
        FilenamePolicyViolation(path: "packages/example/src/components/part-1.tsx", basename: "part-1.tsx"),
        FilenamePolicyViolation(path: "packages/example/src/nested/part-01.ts", basename: "part-01.ts"),
        FilenamePolicyViolation(path: "packages/example/src/part-1.ts", basename: "part-1.ts"),
        FilenamePolicyViolation(path: "vitest-support/part-1.ts", basename: "part-1.ts")
      ]
    )
  }

  func testSourceFilenamePolicyReportsRecreatedRootSourceTree() throws {
    let root = try makeTemporaryRepository()
    try writeFixture(root: root, relativePath: "packages/example/src/workflow-loader.ts")
    try writeFixture(root: root, relativePath: "src/main.ts")

    let result = try checkSourceFilenamePolicy(root: root)

    XCTAssertTrue(result.rootSourceTreePresent)
    XCTAssertEqual(result.violations, [])
  }

  func testChatRedactionLiteralAuditRemainsCoveredWithoutTypeScriptScript() throws {
    let root = try repositoryRoot()
    let violations = try auditChatRedactionLiterals(root: root, scanRoots: ["README.md", "design-docs", "examples"])

    XCTAssertEqual(violations, [], "Unexpected credential, authorization header, raw provider payload, or token-bearing URL literals found")
  }

  func testChatRedactionLiteralAuditUsesExactAllowlistAndDetectsCredentials() throws {
    let root = try makeTemporaryRepository()
    try writeFixture(
      root: root,
      relativePath: "examples/event-sources/README.md",
      contents: """
      export RIELA_DISCORD_BOT_TOKEN=<discord-bot-token>
      export RIELA_TELEGRAM_BOT_TOKEN=<telegram-bot-token>
      """
    )
    try writeFixture(
      root: root,
      relativePath: "examples/unsafe.md",
      contents: """
      authorization: Bearer real-secret-token
      https://api.telegram.org/bot123456:ABCDEF/sendMessage
      access_token=literal-secret
      secret-token
      raw provider body
      """
    )

    let violations = try auditChatRedactionLiterals(root: root, scanRoots: ["examples"])

    XCTAssertEqual(
      violations.map { "\($0.filePath):\($0.rule)" },
      [
        "examples/unsafe.md:authorization-bearer-literal",
        "examples/unsafe.md:telegram-token-bearing-url",
        "examples/unsafe.md:matrix-access-token-url",
        "examples/unsafe.md:known-test-secret-literal",
        "examples/unsafe.md:raw-provider-body-literal"
      ]
    )
  }

  func testTimeSignalShellNormalizesOffsetTimestampLikeTypeScriptDate() throws {
    let output = try runTimeSignalScript(
      scheduledAt: "2026-05-31T10:05:00+09:00",
      timezone: "Asia/Tokyo"
    )

    XCTAssertEqual(output.payload.scheduledAt, "2026-05-31T01:05:00.000Z")
    XCTAssertEqual(output.payload.localTime, "2026-05-31 10:05")
    XCTAssertTrue(output.payload.shouldAnnounce)
    XCTAssertTrue(output.when.shouldAnnounce)
  }

  func testTimeSignalShellNormalizesOffsetTimestampWithoutGNUDate() throws {
    let output = try runTimeSignalScript(
      scheduledAt: "2026-05-31T10:05:00+09:00",
      timezone: "Asia/Tokyo",
      environmentOverrides: ["PATH": "/usr/bin:/bin"]
    )

    XCTAssertEqual(output.payload.scheduledAt, "2026-05-31T01:05:00.000Z")
    XCTAssertEqual(output.payload.localTime, "2026-05-31 10:05")
    XCTAssertTrue(output.payload.shouldAnnounce)
  }

  func testTimeSignalShellPreservesFractionalMilliseconds() throws {
    let output = try runTimeSignalScript(
      scheduledAt: "2026-05-31T10:05:00.123+09:00",
      timezone: "Asia/Tokyo"
    )

    XCTAssertEqual(output.payload.scheduledAt, "2026-05-31T01:05:00.123Z")
    XCTAssertEqual(output.payload.localTime, "2026-05-31 10:05")
  }

  func testTimeSignalShellRejectsInvalidTimezone() throws {
    let result = try runTimeSignalScriptResult(
      scheduledAt: "2026-05-31T10:05:00.000Z",
      timezone: "Not/AZone"
    )

    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssertTrue(result.stderr.contains("invalid timezone: Not/AZone"), result.stderr)
  }

  private func checkSourceFilenamePolicy(root: URL) throws -> FilenamePolicyCheckResult {
    let rootSourceTreePresent = FileManager.default.fileExists(atPath: root.appendingPathComponent("src").path)
    let sourceRoots = try collectPackageSourceRoots(root: root)
    let sourceFiles = try sourceRoots.flatMap { try collectFiles(root: root, relativePath: $0) }
    let vitestSupportFiles = try collectFiles(root: root, relativePath: "vitest-support")
    let filesInBiomeScope = (sourceFiles + vitestSupportFiles + ["vitest.config.ts"]).sorted()
    let violations = filesInBiomeScope.compactMap { file -> FilenamePolicyViolation? in
      let basename = URL(fileURLWithPath: file).lastPathComponent
      guard isForbiddenSourcePartBasename(basename) else {
        return nil
      }
      return FilenamePolicyViolation(path: file, basename: basename)
    }

    return FilenamePolicyCheckResult(
      violations: violations,
      rootSourceTreePresent: rootSourceTreePresent
    )
  }

  private func collectPackageSourceRoots(root: URL) throws -> [String] {
    let packagesURL = root.appendingPathComponent("packages")
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: packagesURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      return []
    }

    return try FileManager.default.contentsOfDirectory(at: packagesURL, includingPropertiesForKeys: [.isDirectoryKey])
      .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
      .map { "packages/\($0.lastPathComponent)/src" }
      .sorted()
  }

  private func isForbiddenSourcePartBasename(_ basename: String) -> Bool {
    basename.range(of: #"^part-\d+\.tsx?$"#, options: .regularExpression) != nil
  }

  private func auditChatRedactionLiterals(root: URL, scanRoots: [String]) throws -> [AuditViolation] {
    let files = try scanRoots.flatMap { try collectFiles(root: root, relativePath: $0) }
      .filter { [".json", ".md", ".ts"].contains(URL(fileURLWithPath: $0).pathExtensionWithDot) }
      .sorted()
    let rules: [(String, NSRegularExpression)] = [
      ("telegram-token-bearing-url", try NSRegularExpression(pattern: #"(?:api\.telegram\.org/(?:file/)?bot|/(?:file/)?bot)(?![$\{<])([A-Za-z0-9:_-]{6,})"#, options: [.caseInsensitive])),
      ("matrix-access-token-url", try NSRegularExpression(pattern: #"access_token=(?![$\{<])([^&"'\s)]+)"#, options: [.caseInsensitive])),
      ("authorization-bearer-literal", try NSRegularExpression(pattern: #"authorization["'\s:]+Bearer\s+(?![$\{<])([A-Za-z0-9._:-]{6,})"#, options: [.caseInsensitive])),
      ("exported-secret-literal", try NSRegularExpression(pattern: #"export\s+[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD)[A-Z0-9_]*=(?!<)([^\s]+)"#, options: [.caseInsensitive])),
      ("known-test-secret-literal", try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_-])(telegram-secret|matrix-bot-token|secret-token|url-secret|mika-token|bot-token)(?![A-Za-z0-9_-])"#, options: [.caseInsensitive])),
      ("raw-provider-body-literal", try NSRegularExpression(pattern: #"raw provider body"#, options: [.caseInsensitive]))
    ]

    var violations: [AuditViolation] = []
    for file in files {
      let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
      for (lineIndex, line) in text.components(separatedBy: .newlines).enumerated() {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        for (rule, regex) in rules {
          for match in regex.matches(in: line, range: range) {
            guard let matchRange = Range(match.range, in: line) else {
              continue
            }
            let evidence = String(line[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !isAllowedRedactionFixture(filePath: file, line: line, evidence: evidence) {
              violations.append(AuditViolation(
                filePath: file,
                lineNumber: lineIndex + 1,
                rule: rule,
                evidence: evidence
              ))
            }
          }
        }
      }
    }

    return violations
  }

  private func isAllowedRedactionFixture(filePath: String, line: String, evidence: String) -> Bool {
    exactAllowedRedactionFixtures[filePath]?.contains(line.trimmingCharacters(in: .whitespacesAndNewlines)) == true
      || exactAllowedEvidenceFixtures[filePath]?.contains(evidence) == true
  }

  private var exactAllowedRedactionFixtures: [String: Set<String>] {
    [
      "examples/event-sources/README.md": [
        "export RIELA_DISCORD_BOT_TOKEN=<discord-bot-token>",
        "export RIELA_TELEGRAM_BOT_TOKEN=<telegram-bot-token>"
      ]
    ]
  }

  private var exactAllowedEvidenceFixtures: [String: Set<String>] {
    [
      "packages/riela/src/events/adapters/telegram-gateway.test.ts": ["telegram-secret"],
      "packages/riela/src/events/adapters/discord-gateway.test.ts": ["bot-token", "mika-token"],
      "packages/riela/src/events/adapters/matrix.test.ts": [
        "Authorization: Bearer matrix-bot-token raw provider body",
        "access_token=url-secret",
        "matrix-bot-token",
        "raw provider body",
        "secret-token",
        "url-secret"
      ],
      "packages/riela/src/events/adapters/chat-sdk.test.ts": ["secret-token"]
    ]
  }

  private func collectRepositoryFiles() throws -> [String] {
    let root = try repositoryRoot()
    return try collectFiles(root: root, relativePath: ".")
      .filter { file in
        !file.hasPrefix(".git/")
          && !file.hasPrefix(".build/")
          && !file.hasPrefix(".direnv/")
          && !file.hasPrefix("dist/")
          && !file.hasPrefix("tmp/")
      }
      .sorted()
  }

  private func collectFiles(root: URL, relativePath: String) throws -> [String] {
    let url = root.appendingPathComponent(relativePath)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return []
    }
    if !isDirectory.boolValue {
      return [relativePath]
    }

    let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey])
    var files: [String] = []
    for child in contents {
      let childRelative = relativePath == "." ? child.lastPathComponent : "\(relativePath)/\(child.lastPathComponent)"
      let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
      if values.isDirectory == true {
        files.append(contentsOf: try collectFiles(root: root, relativePath: childRelative))
      } else if values.isRegularFile == true {
        files.append(childRelative)
      }
    }
    return files
  }

  private func makeTemporaryRepository() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-source-deletion-readiness-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    temporaryDirectories.append(root)
    return root
  }

  private func writeFixture(root: URL, relativePath: String, contents: String = "") throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
  }

  private func runTimeSignalScript(
    scheduledAt: String,
    timezone: String,
    environmentOverrides: [String: String] = [:]
  ) throws -> TimeSignalOutput {
    let result = try runTimeSignalScriptResult(
      scheduledAt: scheduledAt,
      timezone: timezone,
      environmentOverrides: environmentOverrides
    )

    if result.exitCode != 0 {
      XCTFail("prepare-time-signal.sh failed with exit \(result.exitCode): \(result.stderr)")
    }

    return try JSONDecoder().decode(TimeSignalOutput.self, from: Data(result.stdout.utf8))
  }

  private func runTimeSignalScriptResult(
    scheduledAt: String,
    timezone: String,
    environmentOverrides: [String: String] = [:]
  ) throws -> ScriptResult {
    let root = try repositoryRoot()
    let script = root.appendingPathComponent("examples/telegram-agent-trio-time-signal/scripts/prepare-time-signal.sh")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [script.path, scheduledAt, timezone]
    if !environmentOverrides.isEmpty {
      process.environment = ProcessInfo.processInfo.environment.merging(environmentOverrides) { _, override in override }
    }

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

  private func runScript(root: URL, relativePath: String) throws -> ScriptResult {
    let process = Process()
    process.currentDirectoryURL = root
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [root.appendingPathComponent(relativePath).path]

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
    throw NSError(domain: "SourceDeletionReadinessTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Package.swift not found"])
  }
}

private struct FilenamePolicyViolation: Equatable {
  var path: String
  var basename: String
}

private struct FilenamePolicyCheckResult {
  var violations: [FilenamePolicyViolation]
  var rootSourceTreePresent: Bool
}

private struct AuditViolation: Equatable {
  var filePath: String
  var lineNumber: Int
  var rule: String
  var evidence: String
}

private struct TimeSignalOutput: Decodable {
  var when: TimeSignalWhen
  var payload: TimeSignalPayload
}

private struct TimeSignalWhen: Decodable {
  var shouldAnnounce: Bool

  private enum CodingKeys: String, CodingKey {
    case shouldAnnounce = "should_announce"
  }
}

private struct TimeSignalPayload: Decodable {
  var shouldAnnounce: Bool
  var scheduledAt: String
  var localTime: String
}

private struct ScriptResult {
  var exitCode: Int32
  var stdout: String
  var stderr: String
}

private extension URL {
  var pathExtensionWithDot: String {
    let ext = pathExtension
    return ext.isEmpty ? "" : ".\(ext)"
  }
}
