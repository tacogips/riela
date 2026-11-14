import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class FileMarkdownAddonTests: XCTestCase {
  func testConvertsASingleDocumentAndReportsTheResolvedFormat() async throws {
    let fake = try FakeAnydocSwift()
    defer { fake.cleanup() }
    let document = try fake.writeDocument(named: "report.pdf", bytes: 12)

    let output = try await runFileMarkdownConvert(
      config: ["binaryPath": .string(fake.executableURL.path)],
      addonInputs: ["path": .string(document.path)]
    )

    XCTAssertEqual(
      try String(contentsOf: fake.argumentLogURL),
      "convert\n\(document.path)\n--json\n"
    )
    XCTAssertEqual(output.payload["status"], .string("ok"))
    XCTAssertEqual(output.payload["documentCount"], .integer(1))
    XCTAssertEqual(output.payload["convertedCount"], .integer(1))
    XCTAssertEqual(output.payload["failedCount"], .integer(0))
    XCTAssertEqual(output.payload["markdown"], .string("# Fixture\n\nBody."))
    XCTAssertEqual(output.when["has_markdown"], true)
    XCTAssertEqual(output.when["has_failures"], false)

    let documents = try XCTUnwrap(fileMarkdownDocuments(output))
    let first = try XCTUnwrap(fileMarkdownObject(documents.first))
    XCTAssertEqual(first["status"], .string("ok"))
    XCTAssertEqual(first["fileName"], .string("report.pdf"))
    XCTAssertEqual(first["format"], .string("pdf"))
    XCTAssertEqual(first["inputByteCount"], .integer(12))
    XCTAssertEqual(first["markdownByteCount"], .integer(Int64("# Fixture\n\nBody.".utf8.count)))
    XCTAssertEqual(first["truncated"], .bool(false))

    let converter = try XCTUnwrap(converterObject(output))
    XCTAssertEqual(converter["source"], .string("config"))
    XCTAssertEqual(converter["version"], .string("0.1.1 (anydoc 0.1.6)"))
  }

  func testConvertsMultipleDocumentsAndJoinsTheirMarkdown() async throws {
    let fake = try FakeAnydocSwift()
    defer { fake.cleanup() }
    let first = try fake.writeDocument(named: "a.pdf", bytes: 4)
    let second = try fake.writeDocument(named: "b.docx", bytes: 4)

    let output = try await runFileMarkdownConvert(
      config: ["binaryPath": .string(fake.executableURL.path)],
      addonInputs: ["paths": .array([.string(first.path), .string(second.path)])]
    )

    XCTAssertEqual(output.payload["documentCount"], .integer(2))
    XCTAssertEqual(
      output.payload["markdown"],
      .string("# Fixture\n\nBody.\n\n---\n\n# Fixture\n\nBody.")
    )
  }

  func testPassesTheConfiguredFormatToTheConverter() async throws {
    let fake = try FakeAnydocSwift()
    defer { fake.cleanup() }
    let document = try fake.writeDocument(named: "table.csv", bytes: 8)

    _ = try await runFileMarkdownConvert(
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "format": .string("CSV")
      ],
      addonInputs: ["path": .string(document.path)]
    )

    XCTAssertEqual(
      try String(contentsOf: fake.argumentLogURL),
      "convert\n\(document.path)\n--json\n--format\ncsv\n"
    )
  }

  /// The converter resolves extension aliases onto its canonical formats, so
  /// the add-on must not reject them.
  func testAcceptsExtensionAliasFormats() async throws {
    let fake = try FakeAnydocSwift()
    defer { fake.cleanup() }
    let document = try fake.writeDocument(named: "book.xlsx", bytes: 8)

    _ = try await runFileMarkdownConvert(
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "format": .string("xlsx")
      ],
      addonInputs: ["path": .string(document.path)]
    )

    XCTAssertTrue(try String(contentsOf: fake.argumentLogURL).contains("--format\nxlsx\n"))
  }

  func testConversionFailureCarriesTheConverterErrorKind() async throws {
    let fake = try FakeAnydocSwift(mode: "conversion-error")
    defer { fake.cleanup() }
    let document = try fake.writeDocument(named: "locked.pdf", bytes: 6)

    await assertFileMarkdownFailure(
      config: ["binaryPath": .string(fake.executableURL.path)],
      addonInputs: ["path": .string(document.path)],
      code: .providerError,
      messageContains: "conversion failed (encrypted)"
    )
  }

  func testContinueOnErrorRecordsFailedDocumentsAndKeepsConverting() async throws {
    let fake = try FakeAnydocSwift(mode: "fail-first")
    defer { fake.cleanup() }
    let failing = try fake.writeDocument(named: "locked.pdf", bytes: 6)
    let succeeding = try fake.writeDocument(named: "ok.pdf", bytes: 6)

    let output = try await runFileMarkdownConvert(
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "continueOnError": .bool(true)
      ],
      addonInputs: ["paths": .array([.string(failing.path), .string(succeeding.path)])]
    )

    XCTAssertEqual(output.payload["documentCount"], .integer(2))
    XCTAssertEqual(output.payload["convertedCount"], .integer(1))
    XCTAssertEqual(output.payload["failedCount"], .integer(1))
    XCTAssertEqual(output.when["has_failures"], true)
    XCTAssertEqual(output.payload["markdown"], .string("# Fixture\n\nBody."))

    let documents = try XCTUnwrap(fileMarkdownDocuments(output))
    let failed = try XCTUnwrap(fileMarkdownObject(documents.first))
    XCTAssertEqual(failed["status"], .string("failed"))
    let error = try XCTUnwrap(fileMarkdownObject(failed["error"]))
    XCTAssertEqual(error["kind"], .string("encrypted"))
    XCTAssertEqual(error["message"], .string("encrypted document: password required"))
  }

  /// `attributesOfItem` does not follow symlinks, so a symlinked document used
  /// to be rejected as "not a regular file" before it reached the converter.
  func testConvertsThroughASymlinkAndReportsTheResolvedPath() async throws {
    let fake = try FakeAnydocSwift()
    defer { fake.cleanup() }
    let document = try fake.writeDocument(named: "report.pdf", bytes: 12)
    let link = fake.rootURL.appendingPathComponent("link.pdf")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: document)

    let output = try await runFileMarkdownConvert(
      config: ["binaryPath": .string(fake.executableURL.path)],
      addonInputs: ["path": .string(link.path)]
    )

    XCTAssertEqual(output.payload["convertedCount"], .integer(1))
    let first = try XCTUnwrap(fileMarkdownObject(fileMarkdownDocuments(output)?.first))
    XCTAssertEqual(first["path"], .string(document.resolvingSymlinksInPath().path))
    XCTAssertEqual(first["requestedPath"], .string(link.path))
    XCTAssertEqual(first["inputByteCount"], .integer(12))
    XCTAssertTrue(
      try String(contentsOf: fake.argumentLogURL).contains(document.resolvingSymlinksInPath().path)
    )
  }

  func testContinueOnErrorRecordsUnresolvableInputsAsFailedDocuments() async throws {
    let fake = try FakeAnydocSwift()
    defer { fake.cleanup() }
    let missing = fake.documentsURL.appendingPathComponent("missing.pdf")
    let present = try fake.writeDocument(named: "ok.pdf", bytes: 6)

    let output = try await runFileMarkdownConvert(
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "continueOnError": .bool(true)
      ],
      addonInputs: ["paths": .array([.string(missing.path), .string(present.path)])]
    )

    XCTAssertEqual(output.payload["convertedCount"], .integer(1))
    XCTAssertEqual(output.payload["failedCount"], .integer(1))
    let failed = try XCTUnwrap(fileMarkdownObject(fileMarkdownDocuments(output)?.first))
    XCTAssertEqual(failed["status"], .string("failed"))
    let error = try XCTUnwrap(fileMarkdownObject(failed["error"]))
    XCTAssertEqual(error["kind"], .string("io"))
    XCTAssertTrue(jsonText(error["message"])?.contains("cannot read") == true)
  }

  func testTruncatesMarkdownAboveTheConfiguredLimit() async throws {
    let fake = try FakeAnydocSwift(mode: "large-markdown")
    defer { fake.cleanup() }
    let document = try fake.writeDocument(named: "big.pdf", bytes: 10)

    let output = try await runFileMarkdownConvert(
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "maxMarkdownBytes": .integer(64)
      ],
      addonInputs: ["path": .string(document.path)]
    )

    let documents = try XCTUnwrap(fileMarkdownDocuments(output))
    let first = try XCTUnwrap(fileMarkdownObject(documents.first))
    XCTAssertEqual(first["truncated"], .bool(true))
    XCTAssertEqual(first["markdownByteCount"], .integer(64))
  }

  /// Truncation must cut on a character boundary, never mid-scalar.
  func testTruncationKeepsMultiByteCharactersIntact() async throws {
    let fake = try FakeAnydocSwift(mode: "multibyte-markdown")
    defer { fake.cleanup() }
    let document = try fake.writeDocument(named: "big.pdf", bytes: 10)

    let output = try await runFileMarkdownConvert(
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "maxMarkdownBytes": .integer(10)
      ],
      addonInputs: ["path": .string(document.path)]
    )

    let first = try XCTUnwrap(fileMarkdownObject(fileMarkdownDocuments(output)?.first))
    // Three-byte characters: a 10-byte budget holds three of them.
    XCTAssertEqual(first["markdown"], .string("あああ"))
    XCTAssertEqual(first["markdownByteCount"], .integer(9))
    XCTAssertEqual(first["truncated"], .bool(true))
  }

  func testResolvesTheConverterFromConfigThenEnvironmentThenPath() async throws {
    let configFake = try FakeAnydocSwift()
    let envFake = try FakeAnydocSwift()
    let pathFake = try FakeAnydocSwift(executableName: "anydoc-swift")
    defer {
      configFake.cleanup()
      envFake.cleanup()
      pathFake.cleanup()
    }
    let document = try configFake.writeDocument(named: "report.pdf", bytes: 3)

    let configOutput = try await runFileMarkdownConvert(
      config: ["binaryPath": .string(configFake.executableURL.path)],
      addonInputs: ["path": .string(document.path)],
      environment: [
        "ANYDOC_SWIFT_BIN": envFake.executableURL.path,
        "PATH": pathFake.binURL.path
      ]
    )
    XCTAssertEqual(converterField(configOutput, "source"), "config")
    XCTAssertEqual(converterField(configOutput, "path"), configFake.executableURL.path)

    let envOutput = try await runFileMarkdownConvert(
      addonInputs: ["path": .string(document.path)],
      environment: [
        "ANYDOC_SWIFT_BIN": envFake.executableURL.path,
        "PATH": pathFake.binURL.path
      ]
    )
    XCTAssertEqual(converterField(envOutput, "source"), "environment")

    let pathOutput = try await runFileMarkdownConvert(
      addonInputs: ["path": .string(document.path)],
      environment: ["PATH": pathFake.binURL.path]
    )
    XCTAssertEqual(converterField(pathOutput, "source"), "path")
    XCTAssertEqual(converterField(pathOutput, "path"), pathFake.executableURL.path)
  }

  func testDoesNotResolveTheConverterFromPayloadVariables() async throws {
    let maliciousFake = try FakeAnydocSwift()
    let envFake = try FakeAnydocSwift()
    defer {
      maliciousFake.cleanup()
      envFake.cleanup()
    }
    let document = try envFake.writeDocument(named: "report.pdf", bytes: 3)

    let output = try await runFileMarkdownConvert(
      addonInputs: [
        "path": .string(document.path),
        "binaryPath": .string("{{binaryPath}}")
      ],
      environment: ["ANYDOC_SWIFT_BIN": envFake.executableURL.path],
      variables: ["binaryPath": .string(maliciousFake.executableURL.path)],
      resolvedInputPayload: ["binaryPath": .string(maliciousFake.executableURL.path)]
    )

    XCTAssertEqual(converterField(output, "source"), "environment")
    XCTAssertFalse(FileManager.default.fileExists(atPath: maliciousFake.argumentLogURL.path))
  }

  func testConverterUsageErrorReportsThePolicyBlockAndVersionHint() async throws {
    let fake = try FakeAnydocSwift(mode: "usage-error")
    defer { fake.cleanup() }
    let document = try fake.writeDocument(named: "report.pdf", bytes: 3)

    await assertFileMarkdownFailure(
      config: ["binaryPath": .string(fake.executableURL.path)],
      addonInputs: ["path": .string(document.path)],
      code: .policyBlocked,
      messageContains: "0.1.1 or newer is required for --json"
    )
  }

  func testMalformedConverterOutputIsInvalidOutput() async throws {
    let fake = try FakeAnydocSwift(mode: "malformed")
    defer { fake.cleanup() }
    let document = try fake.writeDocument(named: "report.pdf", bytes: 3)

    await assertFileMarkdownFailure(
      config: ["binaryPath": .string(fake.executableURL.path)],
      addonInputs: ["path": .string(document.path)],
      code: .invalidOutput,
      messageContains: "not a valid JSON result envelope"
    )
  }

  func testConverterCrashWithoutAResultEnvelopeIsAProviderError() async throws {
    let fake = try FakeAnydocSwift(mode: "crash")
    defer { fake.cleanup() }
    let document = try fake.writeDocument(named: "report.pdf", bytes: 3)

    await assertFileMarkdownFailure(
      config: ["binaryPath": .string(fake.executableURL.path)],
      addonInputs: ["path": .string(document.path)],
      code: .providerError,
      messageContains: "failed with exit code 3: converter crashed"
    )
  }

  func testRejectsMissingDirectoryAndOversizedInputs() async throws {
    let fake = try FakeAnydocSwift()
    defer { fake.cleanup() }
    let document = try fake.writeDocument(named: "report.pdf", bytes: 4_096)

    await assertFileMarkdownFailure(
      config: ["binaryPath": .string(fake.executableURL.path)],
      addonInputs: ["path": .string(fake.rootURL.appendingPathComponent("missing.pdf").path)],
      code: .policyBlocked,
      messageContains: "cannot read"
    )
    await assertFileMarkdownFailure(
      config: ["binaryPath": .string(fake.executableURL.path)],
      addonInputs: ["path": .string(fake.documentsURL.path)],
      code: .policyBlocked,
      messageContains: "requires a regular file"
    )
    await assertFileMarkdownFailure(
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "maxInputBytes": .integer(1_024)
      ],
      addonInputs: ["path": .string(document.path)],
      code: .policyBlocked,
      messageContains: "above config.maxInputBytes"
    )
  }

  func testRejectsInputsOutsideTheConfiguredAllowedRoots() async throws {
    let fake = try FakeAnydocSwift()
    let outside = try FakeAnydocSwift()
    defer {
      fake.cleanup()
      outside.cleanup()
    }
    let allowed = try fake.writeDocument(named: "inside.pdf", bytes: 3)
    let denied = try outside.writeDocument(named: "outside.pdf", bytes: 3)
    let config: JSONObject = [
      "binaryPath": .string(fake.executableURL.path),
      "allowedRoots": .array([.string(fake.documentsURL.path)])
    ]

    let output = try await runFileMarkdownConvert(
      config: config,
      addonInputs: ["path": .string(allowed.path)]
    )
    XCTAssertEqual(output.payload["convertedCount"], .integer(1))

    await assertFileMarkdownFailure(
      config: config,
      addonInputs: ["path": .string(denied.path)],
      code: .policyBlocked,
      messageContains: "outside config.allowedRoots"
    )
  }

  func testRejectsUnsupportedVersionEnvBindingsAndMissingPaths() async throws {
    let fake = try FakeAnydocSwift()
    defer { fake.cleanup() }
    let document = try fake.writeDocument(named: "report.pdf", bytes: 3)

    await assertFileMarkdownFailure(
      version: "2",
      config: ["binaryPath": .string(fake.executableURL.path)],
      addonInputs: ["path": .string(document.path)],
      code: .policyBlocked,
      messageContains: "unsupported riela/file-markdown-convert version '2'"
    )
    await assertFileMarkdownFailure(
      config: ["binaryPath": .string(fake.executableURL.path)],
      addonInputs: ["path": .string(document.path)],
      addonEnv: ["TOKEN": .object(["fromEnv": .string("SECRET")])],
      code: .policyBlocked,
      messageContains: "does not support addon.env"
    )
    await assertFileMarkdownFailure(
      config: ["binaryPath": .string(fake.executableURL.path)],
      addonInputs: [:],
      code: .policyBlocked,
      messageContains: "requires addon.inputs.path or addon.inputs.paths"
    )
    await assertFileMarkdownFailure(
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "maxDocuments": .integer(1)
      ],
      addonInputs: ["paths": .array([.string(document.path), .string(fake.executableURL.path)])],
      code: .policyBlocked,
      messageContains: "above config.maxDocuments"
    )
    await assertFileMarkdownFailure(
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "format": .string("markdown")
      ],
      addonInputs: ["path": .string(document.path)],
      code: .policyBlocked,
      messageContains: "config.format 'markdown' is not supported"
    )
  }

  func testTerminatesTheConverterWhenTheDeadlineExpires() async throws {
    let fake = try FakeAnydocSwift(mode: "sleep")
    defer { fake.cleanup() }
    let document = try fake.writeDocument(named: "report.pdf", bytes: 3)

    let startedAt = Date()
    do {
      _ = try await runFileMarkdownConvert(
        config: ["binaryPath": .string(fake.executableURL.path)],
        addonInputs: ["path": .string(document.path)],
        context: AdapterExecutionContext(deadline: Date().addingTimeInterval(0.1))
      )
      XCTFail("expected the converter deadline to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .timeout)
      XCTAssertTrue(error.message.contains("anydoc-swift exceeded deadline"), error.message)
      XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
    }
  }

  private func runFileMarkdownConvert(
    version: String? = "1",
    config: JSONObject = [:],
    addonInputs: JSONObject = [:],
    addonEnv: JSONObject? = nil,
    environment: [String: String] = [:],
    variables: JSONObject = [:],
    resolvedInputPayload: JSONObject = [:],
    context: AdapterExecutionContext = AdapterExecutionContext()
  ) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(environment: environment).execute(
      WorkflowAddonExecutionInput(
        workflowId: "file-markdown-convert",
        stepId: "convert-document",
        nodeId: "convert-document",
        addon: WorkflowNodeAddonRef(
          name: FileMarkdownAddon.name,
          version: version,
          config: config,
          env: addonEnv,
          inputs: addonInputs
        ),
        variables: variables,
        resolvedInputPayload: resolvedInputPayload
      ),
      context: context
    )
  }

  private func assertFileMarkdownFailure(
    version: String? = "1",
    config: JSONObject = [:],
    addonInputs: JSONObject = [:],
    addonEnv: JSONObject? = nil,
    environment: [String: String] = [:],
    code: AdapterExecutionErrorCode,
    messageContains: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      _ = try await runFileMarkdownConvert(
        version: version,
        config: config,
        addonInputs: addonInputs,
        addonEnv: addonEnv,
        environment: environment
      )
      XCTFail("expected the file markdown add-on to fail", file: file, line: line)
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, code, error.message, file: file, line: line)
      XCTAssertTrue(error.message.contains(messageContains), error.message, file: file, line: line)
    } catch {
      XCTFail("unexpected error: \(error)", file: file, line: line)
    }
  }

  private func fileMarkdownDocuments(_ output: AdapterExecutionOutput) -> [JSONValue]? {
    guard case let .object(fileMarkdown)? = output.payload["fileMarkdown"],
      case let .array(documents)? = fileMarkdown["documents"] else {
      return nil
    }
    return documents
  }

  private func jsonText(_ value: JSONValue?) -> String? {
    guard case let .string(text)? = value else { return nil }
    return text
  }

  private func fileMarkdownObject(_ value: JSONValue?) -> JSONObject? {
    guard case let .object(object)? = value else { return nil }
    return object
  }

  private func converterObject(_ output: AdapterExecutionOutput) -> JSONObject? {
    guard case let .object(fileMarkdown)? = output.payload["fileMarkdown"] else { return nil }
    return fileMarkdownObject(fileMarkdown["converter"])
  }

  private func converterField(_ output: AdapterExecutionOutput, _ key: String) -> String? {
    guard case let .string(value)? = converterObject(output)?[key] else { return nil }
    return value
  }
}

/// Stand-in for the external `anydoc-swift` executable: logs its arguments and
/// prints a `--json` result envelope for the requested mode.
private struct FakeAnydocSwift {
  var rootURL: URL
  var binURL: URL
  var documentsURL: URL
  var executableURL: URL
  var argumentLogURL: URL
  var callCountURL: URL

  init(executableName: String = "fake-anydoc-swift", mode: String = "success") throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-file-markdown-addon-\(UUID().uuidString)", isDirectory: true)
    binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
    documentsURL = rootURL.appendingPathComponent("documents", isDirectory: true)
    executableURL = binURL.appendingPathComponent(executableName)
    argumentLogURL = rootURL.appendingPathComponent("args.log")
    callCountURL = rootURL.appendingPathComponent("calls.log")
    try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
    try script(mode: mode).write(to: executableURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
  }

  func writeDocument(named name: String, bytes: Int) throws -> URL {
    let url = documentsURL.appendingPathComponent(name)
    try Data(repeating: 0x41, count: bytes).write(to: url)
    return url
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: rootURL)
  }

  private func script(mode: String) -> String {
    """
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      printf '0.1.1 (anydoc 0.1.6)\\n'
      exit 0
    fi
    for arg in "$@"; do printf '%s\\n' "$arg" >> "\(argumentLogURL.path)"; done
    printf 'x' >> "\(callCountURL.path)"
    mode="\(mode)"
    if [ "$mode" = "fail-first" ]; then
      if [ "$(/bin/cat "\(callCountURL.path)" | /usr/bin/wc -c | /usr/bin/tr -d ' ')" = "1" ]; then
        mode="conversion-error"
      else
        mode="success"
      fi
    fi
    case "$mode" in
      success)
        printf '{"schemaVersion":1,"status":"ok","format":"pdf","markdown":"# Fixture\\\\n\\\\nBody.","markdownByteCount":16,"input":{"source":"file","path":"%s"},"tool":{"version":"0.1.1","anydoc":"0.1.6"}}\\n' "$2"
        ;;
      multibyte-markdown)
        printf '{"schemaVersion":1,"status":"ok","format":"pdf","markdown":"ああああああ","input":{"source":"file"},"tool":{"version":"0.1.1","anydoc":"0.1.6"}}\\n'
        ;;
      large-markdown)
        body=$(/usr/bin/head -c 4000 /dev/zero | /usr/bin/tr '\\0' 'a')
        printf '{"schemaVersion":1,"status":"ok","format":"pdf","markdown":"%s","input":{"source":"file"},"tool":{"version":"0.1.1","anydoc":"0.1.6"}}\\n' "$body"
        ;;
      conversion-error)
        printf '{"schemaVersion":1,"status":"error","error":{"kind":"encrypted","message":"encrypted document: password required"},"input":{"source":"file"},"tool":{"version":"0.1.1","anydoc":"0.1.6"}}\\n'
        exit 1
        ;;
      usage-error)
        printf 'Unknown argument: --json\\n' >&2
        exit 2
        ;;
      malformed)
        printf 'not json at all\\n'
        ;;
      crash)
        printf 'converter crashed\\n' >&2
        exit 3
        ;;
      sleep)
        /bin/sleep 30
        ;;
    esac
    """
  }
}
