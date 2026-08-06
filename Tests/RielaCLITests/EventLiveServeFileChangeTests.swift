import Foundation
import RielaCore
@testable import RielaCLI
import XCTest

final class EventLiveServeFileChangeTests: XCTestCase {
  func testSourceConfigResolvesRelativeDirectoryAndDefaults() throws {
    let root = try temporaryDirectory()
    let sources = root.appendingPathComponent("sources", isDirectory: true)
    let watched = root.appendingPathComponent("inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)

    let source = try FileChangeWatchSource(
      file: FileChangeWatchSourceFile(id: "docs", directory: "../inbox"),
      configFileURL: sources.appendingPathComponent("docs.json")
    )

    XCTAssertEqual(source.directoryLabel, "../inbox")
    XCTAssertEqual(source.directoryURL.standardizedFileURL.path, watched.standardizedFileURL.resolvingSymlinksInPath().path)
    XCTAssertEqual(source.changeTypes, ["create", "modify", "delete"])
    XCTAssertFalse(source.recursive)
    XCTAssertEqual(source.suffixes, [])
    XCTAssertEqual(source.stabilityWindowMs, FileChangeWatchSource.defaultStabilityWindowMs)
  }

  func testSourceConfigRejectsInvalidValues() throws {
    let root = try temporaryDirectory()
    let configFileURL = root.appendingPathComponent("docs.json")
    let watched = root.appendingPathComponent("inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)

    XCTAssertThrowsError(try FileChangeWatchSource(
      file: FileChangeWatchSourceFile(id: "docs"),
      configFileURL: configFileURL
    ))
    XCTAssertThrowsError(try FileChangeWatchSource(
      file: FileChangeWatchSourceFile(id: "docs", directory: "missing-directory"),
      configFileURL: configFileURL
    ))
    XCTAssertThrowsError(try FileChangeWatchSource(
      file: FileChangeWatchSourceFile(id: "docs", directory: "inbox", changeTypes: []),
      configFileURL: configFileURL
    ))
    XCTAssertThrowsError(try FileChangeWatchSource(
      file: FileChangeWatchSourceFile(id: "docs", directory: "inbox", changeTypes: ["create", "rename"]),
      configFileURL: configFileURL
    ))
    XCTAssertThrowsError(try FileChangeWatchSource(
      file: FileChangeWatchSourceFile(id: "docs", directory: "inbox", changeTypes: ["create", "create"]),
      configFileURL: configFileURL
    ))
    XCTAssertThrowsError(try FileChangeWatchSource(
      file: FileChangeWatchSourceFile(
        id: "docs",
        directory: "inbox",
        filters: FileChangeWatchSourceFile.Filters(suffixes: [".pdf", "docs/.pdf"])
      ),
      configFileURL: configFileURL
    ))
    XCTAssertThrowsError(try FileChangeWatchSource(
      file: FileChangeWatchSourceFile(
        id: "docs",
        directory: "inbox",
        filters: FileChangeWatchSourceFile.Filters(suffixes: [".pdf", ".PDF"])
      ),
      configFileURL: configFileURL
    ))
    XCTAssertThrowsError(try FileChangeWatchSource(
      file: FileChangeWatchSourceFile(id: "docs", directory: "inbox", stabilityWindowMs: -1),
      configFileURL: configFileURL
    ))
    XCTAssertThrowsError(try FileChangeWatchSource(
      file: FileChangeWatchSourceFile(id: "docs", directory: "inbox", stabilityWindowMs: 60_001),
      configFileURL: configFileURL
    ))
  }

  func testStartupSnapshotSuppressesExistingFiles() throws {
    let watched = try temporaryDirectory()
    try write("existing", to: watched.appendingPathComponent("existing.pdf"))
    let source = try makeSource(watched: watched, stabilityWindowMs: 0)
    let state = try FileChangeWatchState(source: source)

    XCTAssertEqual(try state.scanForStableChanges(source: source, now: Date()), [])
  }

  func testCreateModifyDeleteLifecycleWithZeroStabilityWindow() throws {
    let watched = try temporaryDirectory()
    let source = try makeSource(watched: watched, stabilityWindowMs: 0)
    let state = try FileChangeWatchState(source: source)
    let fileURL = watched.appendingPathComponent("doc.pdf")

    try write("v1", to: fileURL)
    let created = try state.scanForStableChanges(source: source, now: Date())
    XCTAssertEqual(created.map(\.changeType), ["create"])
    XCTAssertEqual(created.first?.relativePath, "doc.pdf")
    XCTAssertEqual(created.first?.stat?.size, 2)

    try write("v2-longer", to: fileURL)
    let modified = try state.scanForStableChanges(source: source, now: Date())
    XCTAssertEqual(modified.map(\.changeType), ["modify"])

    XCTAssertEqual(try state.scanForStableChanges(source: source, now: Date()), [])

    try FileManager.default.removeItem(at: fileURL)
    let deleted = try state.scanForStableChanges(source: source, now: Date())
    XCTAssertEqual(deleted.map(\.changeType), ["delete"])
    XCTAssertEqual(deleted.first?.relativePath, "doc.pdf")
    XCTAssertNotNil(deleted.first?.stat)
  }

  func testStabilityWindowCoalescesWriteBursts() throws {
    let watched = try temporaryDirectory()
    let source = try makeSource(watched: watched, stabilityWindowMs: 1_000)
    let state = try FileChangeWatchState(source: source)
    let fileURL = watched.appendingPathComponent("doc.pdf")
    let base = Date()

    try write("v1", to: fileURL)
    XCTAssertEqual(try state.scanForStableChanges(source: source, now: base), [])

    // The file keeps changing, so the pending create stays unstable.
    try write("v2-longer", to: fileURL)
    XCTAssertEqual(try state.scanForStableChanges(source: source, now: base.addingTimeInterval(2)), [])

    // One second of unchanged metadata later, exactly one create dispatches.
    let settled = try state.scanForStableChanges(source: source, now: base.addingTimeInterval(4))
    XCTAssertEqual(settled.map(\.changeType), ["create"])
    XCTAssertEqual(settled.first?.stat?.size, 9)
  }

  func testPendingCreateThatVanishesDispatchesNothing() throws {
    let watched = try temporaryDirectory()
    let source = try makeSource(watched: watched, stabilityWindowMs: 1_000)
    let state = try FileChangeWatchState(source: source)
    let fileURL = watched.appendingPathComponent("doc.pdf")
    let base = Date()

    try write("v1", to: fileURL)
    XCTAssertEqual(try state.scanForStableChanges(source: source, now: base), [])
    try FileManager.default.removeItem(at: fileURL)
    XCTAssertEqual(try state.scanForStableChanges(source: source, now: base.addingTimeInterval(2)), [])
    XCTAssertEqual(try state.scanForStableChanges(source: source, now: base.addingTimeInterval(4)), [])
  }

  func testSuffixFilterIsCaseInsensitiveAndSkipsOtherFiles() throws {
    let watched = try temporaryDirectory()
    let source = try makeSource(watched: watched, stabilityWindowMs: 0, suffixes: [".pdf", ".epub"])
    let state = try FileChangeWatchState(source: source)

    try write("a", to: watched.appendingPathComponent("keep.PDF"))
    try write("b", to: watched.appendingPathComponent("keep.epub"))
    try write("c", to: watched.appendingPathComponent("skip.txt"))
    try write("d", to: watched.appendingPathComponent(".hidden.pdf"))

    let events = try state.scanForStableChanges(source: source, now: Date())
    XCTAssertEqual(events.map(\.relativePath), ["keep.PDF", "keep.epub"])
  }

  func testRecursiveScanCoversSubdirectoriesOnlyWhenEnabled() throws {
    let watched = try temporaryDirectory()
    let nested = watched.appendingPathComponent("sub", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

    let flat = try makeSource(watched: watched, stabilityWindowMs: 0)
    let flatState = try FileChangeWatchState(source: flat)
    let recursive = try makeSource(watched: watched, stabilityWindowMs: 0, recursive: true)
    let recursiveState = try FileChangeWatchState(source: recursive)

    try write("a", to: nested.appendingPathComponent("deep.pdf"))
    XCTAssertEqual(try flatState.scanForStableChanges(source: flat, now: Date()), [])
    let events = try recursiveState.scanForStableChanges(source: recursive, now: Date())
    XCTAssertEqual(events.map(\.relativePath), ["sub/deep.pdf"])
  }

  func testEnvelopeCarriesChangeFileAndWatchPayload() throws {
    let watched = try temporaryDirectory()
    let source = try makeSource(watched: watched, stabilityWindowMs: 0)
    let mtime = Date(timeIntervalSince1970: 1_754_438_400)
    let envelope = source.envelope(for: FileChangeObservedEvent(
      changeType: "create",
      relativePath: "sub/report.pdf",
      stat: FileChangeFileStat(size: 42, mtime: mtime),
      observedAt: mtime
    ))

    XCTAssertEqual(envelope.sourceId, source.id)
    XCTAssertEqual(envelope.eventType.rawValue, "file.change.created")
    XCTAssertEqual(envelope.provider.rawValue, "local-fs")
    guard case let .object(file)? = envelope.input["file"] else {
      return XCTFail("expected file object")
    }
    XCTAssertEqual(file["path"], .string("sub/report.pdf"))
    XCTAssertEqual(file["name"], .string("report.pdf"))
    XCTAssertEqual(file["extension"], .string(".pdf"))
    XCTAssertEqual(file["size"], .integer(42))
    XCTAssertEqual(file["absolutePath"], .string(source.directoryURL.appendingPathComponent("sub/report.pdf").path))
    guard case let .object(watch)? = envelope.input["watch"] else {
      return XCTFail("expected watch object")
    }
    XCTAssertEqual(watch["sourceId"], .string(source.id))
    XCTAssertEqual(watch["resolvedDirectory"], .string(source.directoryURL.path))
    XCTAssertEqual(envelope.input["change"], .object(["type": .string("create")]))
  }

  func testValidateReportsInvalidFileChangeSource() throws {
    let eventRoot = try temporaryDirectory()
    let sources = eventRoot.appendingPathComponent("sources", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try """
    {
      "id": "docs",
      "kind": "file-change",
      "directory": "missing-inbox"
    }
    """.write(to: sources.appendingPathComponent("docs.json"), atomically: true, encoding: .utf8)

    let diagnostics = fileChangeSourceDiagnostics(eventRoot: eventRoot)
    XCTAssertEqual(diagnostics.count, 1)
    XCTAssertEqual(diagnostics.first?.code, "INVALID_EVENT_SOURCE")
    XCTAssertTrue(diagnostics.first?.message.contains("does not exist") == true)
  }

  func testFileChangeServeDispatchesBoundWorkflowForCreatedDocument() async throws {
    let eventRoot = try temporaryDirectory()
    let watched = eventRoot.appendingPathComponent("inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
    try writeFileChangeEventConfig(eventRoot: eventRoot)
    let workflowRunner = FakeEventWorkflowRunner(replyText: "", replyAs: "")
    let server = DefaultEventLiveServer(workflowRunner: workflowRunner)

    let serveTask = Task {
      try await server.serve(
        eventRoot: eventRoot,
        target: nil,
        parsed: try ParsedParityOptions(["--limit", "1"]),
        output: .json
      )
    }
    let watchdog = Task {
      try await Task.sleep(nanoseconds: 30_000_000_000)
      serveTask.cancel()
    }
    defer {
      watchdog.cancel()
    }
    // Give serve time to record its startup snapshot before the drop.
    try await Task.sleep(nanoseconds: 500_000_000)
    try write("%PDF-1.4 demo", to: watched.appendingPathComponent("paper.pdf"))

    let result = try await serveTask.value
    XCTAssertEqual(result.status, "ok")
    XCTAssertTrue(result.records.contains("processedEvents=1"))
    let requests = await workflowRunner.requests
    XCTAssertEqual(requests.map(\.workflowName), ["document-flow"])
    guard case let .object(input)? = requests.first?.runtimeVariables["workflowInput"] else {
      return XCTFail("expected workflowInput object")
    }
    XCTAssertEqual(input["change"], .string("create"))
    XCTAssertEqual(input["path"], .string("paper.pdf"))
    guard case let .string(absolutePath)? = input["absolutePath"] else {
      return XCTFail("expected absolutePath string")
    }
    XCTAssertTrue(absolutePath.hasSuffix("/inbox/paper.pdf"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: absolutePath))
  }

  func testFileChangeServeSurvivesWorkflowRunFailure() async throws {
    let eventRoot = try temporaryDirectory()
    let watched = eventRoot.appendingPathComponent("inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
    try writeFileChangeEventConfig(eventRoot: eventRoot)
    let workflowRunner = FakeEventWorkflowRunner(failureMessage: "conversion failed")
    let server = DefaultEventLiveServer(workflowRunner: workflowRunner)

    let serveTask = Task {
      try await server.serve(
        eventRoot: eventRoot,
        target: nil,
        parsed: try ParsedParityOptions(["--limit", "1"]),
        output: .json
      )
    }
    let watchdog = Task {
      try await Task.sleep(nanoseconds: 30_000_000_000)
      serveTask.cancel()
    }
    defer {
      watchdog.cancel()
    }
    try await Task.sleep(nanoseconds: 500_000_000)
    try write("broken bytes", to: watched.appendingPathComponent("broken.pdf"))

    let result = try await serveTask.value
    XCTAssertEqual(result.status, "ok")
    XCTAssertTrue(result.records.contains("processedEvents=1"))
    let record = try String(contentsOf: eventRoot.appendingPathComponent("serve-record.json"), encoding: .utf8)
    XCTAssertTrue(record.contains("file-change-workflow-failed"))
    XCTAssertTrue(record.contains("conversion failed"))
  }

  private func makeSource(
    watched: URL,
    stabilityWindowMs: Int,
    suffixes: [String]? = nil,
    recursive: Bool = false
  ) throws -> FileChangeWatchSource {
    try FileChangeWatchSource(
      file: FileChangeWatchSourceFile(
        id: "docs",
        directory: watched.path,
        recursive: recursive,
        filters: suffixes.map { FileChangeWatchSourceFile.Filters(suffixes: $0) },
        stabilityWindowMs: stabilityWindowMs
      ),
      configFileURL: watched.appendingPathComponent("unused-config.json")
    )
  }

  private func writeFileChangeEventConfig(eventRoot: URL) throws {
    let sources = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let bindings = eventRoot.appendingPathComponent("bindings", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bindings, withIntermediateDirectories: true)
    try """
    {
      "id": "document-inbox",
      "kind": "file-change",
      "directory": "../inbox",
      "changeTypes": ["create"],
      "filters": {"suffixes": [".pdf", ".epub"]},
      "stabilityWindowMs": 0
    }
    """.write(to: sources.appendingPathComponent("document-inbox.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "document-inbox-to-workflow",
      "sourceId": "document-inbox",
      "workflowName": "document-flow",
      "match": {"eventType": "file.change.created"},
      "inputMapping": {
        "mode": "template",
        "template": {
          "change": "{{event.input.change.type}}",
          "path": "{{event.input.file.path}}",
          "absolutePath": "{{event.input.file.absolutePath}}"
        },
        "mirrorToHumanInput": false
      }
    }
    """.write(to: bindings.appendingPathComponent("document-inbox-to-workflow.json"), atomically: true, encoding: .utf8)
  }

  private func write(_ text: String, to url: URL) throws {
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  private func temporaryDirectory() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-event-live-file-change-tests-\(UUID().uuidString)", isDirectory: true)
      .standardizedFileURL
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }
    return root.resolvingSymlinksInPath()
  }
}
