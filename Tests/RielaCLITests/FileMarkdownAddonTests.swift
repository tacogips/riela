import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

/// The document converter is the linked `AnydocKit` library, so these tests
/// convert real documents rather than stubbing an executable on `PATH`. CSV is
/// used as the fixture format because a valid one is a few bytes of text and
/// its Markdown is deterministic.
final class FileMarkdownAddonTests: XCTestCase {
  func testConvertsASingleDocumentAndReportsTheResolvedFormat() async throws {
    let workspace = try DocumentWorkspace()
    defer { workspace.cleanup() }
    let document = try workspace.writeCSV(named: "report.csv", rows: [["name", "value"], ["alpha", "1"]])

    let output = try await runFileMarkdownConvert(addonInputs: ["path": .string(document.path)])

    XCTAssertEqual(output.payload["status"], .string("ok"))
    XCTAssertEqual(output.payload["documentCount"], .integer(1))
    XCTAssertEqual(output.payload["convertedCount"], .integer(1))
    XCTAssertEqual(output.payload["failedCount"], .integer(0))
    XCTAssertEqual(output.payload["markdown"], .string("| name | value |\n| --- | --- |\n| alpha | 1 |\n"))
    XCTAssertEqual(output.when["has_markdown"], true)
    XCTAssertEqual(output.when["has_failures"], false)

    let documents = try XCTUnwrap(fileMarkdownDocuments(output))
    let first = try XCTUnwrap(fileMarkdownObject(documents.first))
    XCTAssertEqual(first["status"], .string("ok"))
    XCTAssertEqual(first["fileName"], .string("report.csv"))
    XCTAssertEqual(first["format"], .string("csv"))
    XCTAssertEqual(first["truncated"], .bool(false))

    let converter = try XCTUnwrap(converterObject(output))
    XCTAssertEqual(converter["mode"], .string("in-process"))
    XCTAssertEqual(converter["library"], .string("anydoc-swift"))
    // The pinned native converter version, not a CLI's `--version` string.
    XCTAssertFalse(converterField(output, "version")?.isEmpty ?? true)
  }

  func testConvertsMultipleDocumentsAndJoinsTheirMarkdown() async throws {
    let workspace = try DocumentWorkspace()
    defer { workspace.cleanup() }
    let first = try workspace.writeCSV(named: "a.csv", rows: [["a"], ["1"]])
    let second = try workspace.writeCSV(named: "b.csv", rows: [["b"], ["2"]])

    let output = try await runFileMarkdownConvert(
      addonInputs: ["paths": .array([.string(first.path), .string(second.path)])]
    )

    XCTAssertEqual(output.payload["documentCount"], .integer(2))
    XCTAssertEqual(output.payload["convertedCount"], .integer(2))
    let markdown = try XCTUnwrap(jsonText(output.payload["markdown"]))
    XCTAssertTrue(markdown.contains("\n\n---\n\n"), markdown)
    XCTAssertTrue(markdown.contains("| a |"), markdown)
    XCTAssertTrue(markdown.contains("| b |"), markdown)
  }

  /// CSV carries no content signature, so an unnamed extension only converts
  /// when `config.format` names it.
  func testPassesTheConfiguredFormatToTheConverter() async throws {
    let workspace = try DocumentWorkspace()
    defer { workspace.cleanup() }
    let document = try workspace.writeCSV(named: "table.data", rows: [["name"], ["alpha"]])

    let output = try await runFileMarkdownConvert(
      config: ["format": .string("CSV")],
      addonInputs: ["path": .string(document.path)]
    )
    XCTAssertEqual(output.payload["convertedCount"], .integer(1))
    let first = try XCTUnwrap(fileMarkdownObject(fileMarkdownDocuments(output)?.first))
    XCTAssertEqual(first["format"], .string("csv"))

    await assertFileMarkdownFailure(
      addonInputs: ["path": .string(document.path)],
      code: .providerError,
      messageContains: "unsupported"
    )
  }

  /// The converter resolves extension aliases onto its canonical formats, so
  /// the add-on must not reject them at validation time.
  func testAcceptsExtensionAliasFormats() async throws {
    let workspace = try DocumentWorkspace()
    defer { workspace.cleanup() }
    let document = try workspace.writeCSV(named: "book.xlsx", rows: [["a"], ["1"]])

    // `xlsx` is an alias for `excel`, so it passes validation and reaches the
    // converter — which then rejects the CSV bytes as malformed rather than
    // the add-on rejecting the format name.
    await assertFileMarkdownFailure(
      config: ["format": .string("xlsx")],
      addonInputs: ["path": .string(document.path)],
      code: .providerError,
      messageContains: "conversion failed"
    )
  }

  func testConversionFailureCarriesTheConverterErrorKind() async throws {
    let workspace = try DocumentWorkspace()
    defer { workspace.cleanup() }
    let document = try workspace.write(named: "locked.pdf", text: "this is not a PDF")

    await assertFileMarkdownFailure(
      addonInputs: ["path": .string(document.path)],
      code: .providerError,
      messageContains: "conversion failed (malformed)"
    )
  }

  func testContinueOnErrorRecordsFailedDocumentsAndKeepsConverting() async throws {
    let workspace = try DocumentWorkspace()
    defer { workspace.cleanup() }
    let failing = try workspace.write(named: "broken.pdf", text: "this is not a PDF")
    let succeeding = try workspace.writeCSV(named: "ok.csv", rows: [["a"], ["1"]])

    let output = try await runFileMarkdownConvert(
      config: ["continueOnError": .bool(true)],
      addonInputs: ["paths": .array([.string(failing.path), .string(succeeding.path)])]
    )

    XCTAssertEqual(output.payload["documentCount"], .integer(2))
    XCTAssertEqual(output.payload["convertedCount"], .integer(1))
    XCTAssertEqual(output.payload["failedCount"], .integer(1))
    XCTAssertEqual(output.when["has_failures"], true)
    XCTAssertTrue(try XCTUnwrap(jsonText(output.payload["markdown"])).contains("| a |"))

    let documents = try XCTUnwrap(fileMarkdownDocuments(output))
    let failed = try XCTUnwrap(fileMarkdownObject(documents.first))
    XCTAssertEqual(failed["status"], .string("failed"))
    let error = try XCTUnwrap(fileMarkdownObject(failed["error"]))
    XCTAssertEqual(error["kind"], .string("malformed"))
  }

  /// `attributesOfItem` does not follow symlinks, so a symlinked document used
  /// to be rejected as "not a regular file" before it reached the converter.
  func testConvertsThroughASymlinkAndReportsTheResolvedPath() async throws {
    let workspace = try DocumentWorkspace()
    defer { workspace.cleanup() }
    let document = try workspace.writeCSV(named: "report.csv", rows: [["a"], ["1"]])
    let link = workspace.rootURL.appendingPathComponent("link.csv")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: document)

    let output = try await runFileMarkdownConvert(addonInputs: ["path": .string(link.path)])

    XCTAssertEqual(output.payload["convertedCount"], .integer(1))
    let first = try XCTUnwrap(fileMarkdownObject(fileMarkdownDocuments(output)?.first))
    XCTAssertEqual(first["path"], .string(document.resolvingSymlinksInPath().path))
    XCTAssertEqual(first["requestedPath"], .string(link.path))
  }

  func testContinueOnErrorRecordsUnresolvableInputsAsFailedDocuments() async throws {
    let workspace = try DocumentWorkspace()
    defer { workspace.cleanup() }
    let missing = workspace.documentsURL.appendingPathComponent("missing.csv")
    let present = try workspace.writeCSV(named: "ok.csv", rows: [["a"], ["1"]])

    let output = try await runFileMarkdownConvert(
      config: ["continueOnError": .bool(true)],
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
    let workspace = try DocumentWorkspace()
    defer { workspace.cleanup() }
    let rows = [["name", "value"]] + (0..<200).map { ["row-\($0)", "\($0)"] }
    let document = try workspace.writeCSV(named: "big.csv", rows: rows)

    let output = try await runFileMarkdownConvert(
      config: ["maxMarkdownBytes": .integer(64)],
      addonInputs: ["path": .string(document.path)]
    )

    let first = try XCTUnwrap(fileMarkdownObject(fileMarkdownDocuments(output)?.first))
    XCTAssertEqual(first["truncated"], .bool(true))
    XCTAssertEqual(first["markdownByteCount"], .integer(64))
  }

  /// Truncation must cut on a character boundary, never mid-scalar.
  func testTruncationKeepsMultiByteCharactersIntact() async throws {
    let workspace = try DocumentWorkspace()
    defer { workspace.cleanup() }
    // Markdown starts `| あ | ...`; the three-byte character spans bytes 2-4,
    // so a four-byte budget has to stop before it rather than inside it.
    let document = try workspace.writeCSV(named: "multibyte.csv", rows: [["あ", "い"], ["1", "2"]])

    let output = try await runFileMarkdownConvert(
      config: ["maxMarkdownBytes": .integer(4)],
      addonInputs: ["path": .string(document.path)]
    )

    let first = try XCTUnwrap(fileMarkdownObject(fileMarkdownDocuments(output)?.first))
    XCTAssertEqual(first["markdown"], .string("| "))
    XCTAssertEqual(first["markdownByteCount"], .integer(2))
    XCTAssertEqual(first["truncated"], .bool(true))
  }

  /// The converter is linked in, so there is no executable to point at and a
  /// leftover `binaryPath` must fail loudly instead of being ignored.
  func testConfiguredBinaryPathIsRefused() async throws {
    let workspace = try DocumentWorkspace()
    defer { workspace.cleanup() }
    let document = try workspace.writeCSV(named: "report.csv", rows: [["a"], ["1"]])

    await assertFileMarkdownFailure(
      config: ["binaryPath": .string("/usr/bin/true")],
      addonInputs: ["path": .string(document.path)],
      code: .policyBlocked,
      messageContains: "config.binaryPath is not supported"
    )
  }

  func testRejectsMissingDirectoryAndOversizedInputs() async throws {
    let workspace = try DocumentWorkspace()
    defer { workspace.cleanup() }
    let document = try workspace.write(named: "report.csv", text: String(repeating: "a,b\n", count: 1_024))

    await assertFileMarkdownFailure(
      addonInputs: ["path": .string(workspace.rootURL.appendingPathComponent("missing.csv").path)],
      code: .policyBlocked,
      messageContains: "cannot read"
    )
    await assertFileMarkdownFailure(
      addonInputs: ["path": .string(workspace.documentsURL.path)],
      code: .policyBlocked,
      messageContains: "requires a regular file"
    )
    await assertFileMarkdownFailure(
      config: ["maxInputBytes": .integer(1_024)],
      addonInputs: ["path": .string(document.path)],
      code: .policyBlocked,
      messageContains: "above config.maxInputBytes"
    )
  }

  func testRejectsInputsOutsideTheConfiguredAllowedRoots() async throws {
    let workspace = try DocumentWorkspace()
    let outside = try DocumentWorkspace()
    defer {
      workspace.cleanup()
      outside.cleanup()
    }
    let allowed = try workspace.writeCSV(named: "inside.csv", rows: [["a"], ["1"]])
    let denied = try outside.writeCSV(named: "outside.csv", rows: [["a"], ["1"]])
    let config: JSONObject = ["allowedRoots": .array([.string(workspace.documentsURL.path)])]

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
    let workspace = try DocumentWorkspace()
    defer { workspace.cleanup() }
    let document = try workspace.writeCSV(named: "report.csv", rows: [["a"], ["1"]])
    let second = try workspace.writeCSV(named: "second.csv", rows: [["b"], ["2"]])

    await assertFileMarkdownFailure(
      version: "2",
      addonInputs: ["path": .string(document.path)],
      code: .policyBlocked,
      messageContains: "unsupported riela/file-markdown-convert version '2'"
    )
    await assertFileMarkdownFailure(
      addonInputs: ["path": .string(document.path)],
      addonEnv: ["TOKEN": .object(["fromEnv": .string("SECRET")])],
      code: .policyBlocked,
      messageContains: "does not support addon.env"
    )
    await assertFileMarkdownFailure(
      addonInputs: [:],
      code: .policyBlocked,
      messageContains: "requires addon.inputs.path or addon.inputs.paths"
    )
    await assertFileMarkdownFailure(
      config: ["maxDocuments": .integer(1)],
      addonInputs: ["paths": .array([.string(document.path), .string(second.path)])],
      code: .policyBlocked,
      messageContains: "above config.maxDocuments"
    )
    await assertFileMarkdownFailure(
      config: ["format": .string("markdown")],
      addonInputs: ["path": .string(document.path)],
      code: .policyBlocked,
      messageContains: "config.format 'markdown' is not supported"
    )
  }

  /// A deadline that has already passed fails the step instead of starting a
  /// conversion that cannot be interrupted.
  func testExpiredDeadlineFailsBeforeConverting() async throws {
    let workspace = try DocumentWorkspace()
    defer { workspace.cleanup() }
    let document = try workspace.writeCSV(named: "report.csv", rows: [["a"], ["1"]])

    do {
      _ = try await runFileMarkdownConvert(
        addonInputs: ["path": .string(document.path)],
        context: AdapterExecutionContext(deadline: Date().addingTimeInterval(-1))
      )
      XCTFail("expected the converter deadline to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .timeout)
      XCTAssertTrue(error.message.contains("exceeded deadline"), error.message)
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
/// A temporary directory of real documents for the linked converter.
private struct DocumentWorkspace {
  var rootURL: URL
  var documentsURL: URL

  init() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-file-markdown-addon-\(UUID().uuidString)", isDirectory: true)
    documentsURL = rootURL.appendingPathComponent("documents", isDirectory: true)
    try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
  }

  func write(named name: String, text: String) throws -> URL {
    let url = documentsURL.appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  func writeCSV(named name: String, rows: [[String]]) throws -> URL {
    try write(named: name, text: rows.map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n")
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
