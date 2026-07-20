import Foundation
import RielaNote
@testable import RielaNoteUI
import XCTest

@MainActor
final class RielaNoteEditRewriteTests: XCTestCase {
  func testViewModelProposesBodyRewriteAndRecordsSummary() async throws {
    let client = RewriteTestClient()
    client.rewriteDraft = RielaNoteEditRewriteDraft(
      rewrittenMarkdown: "replacement text",
      summary: "Tightened selected text."
    )
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.selectNote("note-2")
    let draft = await viewModel.proposeBodyRewrite(
      instruction: "Make this concise",
      draftBodyMarkdown: "# Ontology\n\nSearch body",
      selectedText: "Search",
      selectionStart: 12,
      selectionEnd: 18
    )

    XCTAssertEqual(draft?.rewrittenMarkdown, "replacement text")
    XCTAssertEqual(viewModel.editRewriteSummary, "Tightened selected text.")
    XCTAssertNil(viewModel.editRewriteError)
    XCTAssertFalse(viewModel.isEditRewriteLoading)
    XCTAssertEqual(client.rewriteRequests, [
      RewriteTestClient.RewriteRequest(
        noteId: "note-2",
        instruction: "Make this concise",
        bodyMarkdown: "# Ontology\n\nSearch body",
        selectedText: "Search",
        selectionStart: 12,
        selectionEnd: 18
      )
    ])
  }

  func testViewModelSurfacesBodyRewriteFailure() async throws {
    let client = RewriteTestClient()
    client.rewriteError = RielaNoteEditRewriteError.notConfigured
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.selectNote("note-2")
    let draft = await viewModel.proposeBodyRewrite(
      instruction: "Improve",
      draftBodyMarkdown: "# Ontology",
      selectedText: nil,
      selectionStart: nil,
      selectionEnd: nil
    )

    XCTAssertNil(draft)
    XCTAssertEqual(viewModel.editRewriteError, "Edit agent is not configured.")
    XCTAssertNil(viewModel.editRewriteSummary)
    XCTAssertFalse(viewModel.isEditRewriteLoading)
  }

  func testViewModelDropsStaleBodyRewriteAfterNoteSwitch() async throws {
    let client = RewriteTestClient()
    client.rewriteDelayNanoseconds = 50_000_000
    client.rewriteDraft = RielaNoteEditRewriteDraft(rewrittenMarkdown: "late", summary: "Late")
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.selectNote("note-2")
    let rewrite = Task {
      await viewModel.proposeBodyRewrite(
        instruction: "Improve",
        draftBodyMarkdown: "# Ontology",
        selectedText: nil,
        selectionStart: nil,
        selectionEnd: nil
      )
    }
    try await Task.sleep(nanoseconds: 5_000_000)
    await viewModel.selectNote("note-1")
    let draft = await rewrite.value

    XCTAssertNil(draft)
    XCTAssertNil(viewModel.editRewriteSummary)
    XCTAssertNil(viewModel.editRewriteError)
    XCTAssertFalse(viewModel.isEditRewriteLoading)
  }

  func testNoteServiceClientBodyRewriteProviderRoundTrip() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Draft\n\nBody")
    let provider = CapturingEditRewriteProvider(
      draft: RielaNoteEditRewriteDraft(rewrittenMarkdown: "# Draft\n\nUpdated", summary: "Updated")
    )
    let client = NoteServiceRielaNoteUIClient(service: service, editRewriteProvider: provider)

    let draft = try await client.proposeNoteBodyRewrite(
      noteId: note.noteId,
      instruction: "Update",
      bodyMarkdown: "# Draft\n\nBody",
      selectedText: "Body",
      selectionStart: 9,
      selectionEnd: 13
    )

    XCTAssertEqual(draft.summary, "Updated")
    XCTAssertEqual(provider.requests.first?.noteId, note.noteId)
    XCTAssertEqual(provider.requests.first?.noteRoot, service.noteRootPath())
    XCTAssertEqual(provider.requests.first?.bodyMarkdown, "# Draft\n\nBody")
    XCTAssertEqual(provider.requests.first?.selectedText, "Body")
  }

  func testNoteServiceClientBodyRewriteWithoutProviderThrowsNotConfigured() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Draft\n\nBody")
    let client = NoteServiceRielaNoteUIClient(service: service)

    do {
      _ = try await client.proposeNoteBodyRewrite(
        noteId: note.noteId,
        instruction: "Update",
        bodyMarkdown: note.bodyMarkdown,
        selectedText: nil,
        selectionStart: nil,
        selectionEnd: nil
      )
      XCTFail("Expected notConfigured")
    } catch RielaNoteEditRewriteError.notConfigured {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testApplyingRewriteSplicesValidUTF16Range() {
    let draft = "Before cafe After"
    let range = (draft as NSString).range(of: "cafe")

    let updated = rielaNoteApplyingRewrite(draft: draft, range: range, replacement: "coffee")

    XCTAssertEqual(updated, "Before coffee After")
  }

  func testApplyingRewriteHandlesEmojiUTF16Range() {
    let draft = "Start 🧠 idea End"
    let range = (draft as NSString).range(of: "🧠 idea")

    let updated = rielaNoteApplyingRewrite(draft: draft, range: range, replacement: "brainstorm")

    XCTAssertEqual(updated, "Start brainstorm End")
  }

  func testApplyingRewriteRejectsInvalidRange() {
    let draft = "Short"

    XCTAssertNil(rielaNoteApplyingRewrite(
      draft: draft,
      range: NSRange(location: 99, length: 5),
      replacement: "Nope"
    ))
  }

  func testRewriteRangeValidityDrivesSelectionScopeGate() {
    let draft = "Alpha beta gamma"
    let selection = (draft as NSString).range(of: "beta")

    XCTAssertTrue(rielaNoteRewriteRangeIsValid(selection, in: draft))
    XCTAssertFalse(rielaNoteRewriteRangeIsValid(NSRange(location: 3, length: 0), in: draft))
    XCTAssertFalse(rielaNoteRewriteRangeIsValid(NSRange(location: 40, length: 4), in: draft))
  }

  func testRewriteResultFreshnessRejectsEditedDraftsAndStaleSelection() {
    let submittedDraft = "One selected three"
    let submittedRange = (submittedDraft as NSString).range(of: "selected")

    XCTAssertTrue(rielaNoteRewriteResultIsFresh(
      currentDraft: submittedDraft,
      submittedDraft: submittedDraft,
      submittedRange: submittedRange,
      submittedSelectedText: "selected"
    ))
    XCTAssertFalse(rielaNoteRewriteResultIsFresh(
      currentDraft: "One selected three changed",
      submittedDraft: submittedDraft,
      submittedRange: submittedRange,
      submittedSelectedText: "selected"
    ))
    XCTAssertFalse(rielaNoteRewriteResultIsFresh(
      currentDraft: submittedDraft,
      submittedDraft: submittedDraft,
      submittedRange: submittedRange,
      submittedSelectedText: "different"
    ))
  }

  func testExportFilenameUsesSafeTitleOrNoteId() {
    XCTAssertEqual(rielaNoteExportFilename(title: "Project: Plan / Next", noteId: "note-1"), "project-plan-next.md")
    XCTAssertEqual(rielaNoteExportFilename(title: "   ", noteId: "note-2"), "note-2.md")
  }

  func testDisplayedMarkdownUsesDraftOnlyWhileEditing() {
    XCTAssertEqual(
      rielaNoteDisplayedMarkdown(noteMarkdown: "saved", draftMarkdown: "draft", isEditing: true),
      "draft"
    )
    XCTAssertEqual(
      rielaNoteDisplayedMarkdown(noteMarkdown: "saved", draftMarkdown: "draft", isEditing: false),
      "saved"
    )
  }

  // MARK: - Restored edit-agent UI reachability (TASK-013, F12)

  // The detail view carries the restored edit-agent pill / selection Q&A flow;
  // constructing it proves the restored SwiftUI body — which references
  // `proposeBodyRewrite`, `askSelectionQuestion`, and
  // `RielaNoteSelectableTextEditor` — compiles and is wired to the live
  // view-model rather than the dead-code state before the snapshot regression.
  func testDetailViewConstructsWithRestoredEditAgentSurface() async throws {
    let client = RewriteTestClient()
    let viewModel = RielaNoteLibraryViewModel(client: client)
    await viewModel.selectNote("note-2")

    _ = RielaNoteDetailView(viewModel: viewModel)
    _ = RielaNoteSelectableTextEditor(
      text: .constant("editor body"),
      selectedRange: .constant(NSRange(location: 0, length: 0))
    )
  }

  #if os(macOS)
  func testWorkflowEditRewriteVariablesIncludeSelectionFields() throws {
    let variables = noteEditRewriteVariables(
      noteId: "note-1",
      noteRoot: "/tmp/notes",
      instruction: "Improve",
      bodyMarkdown: "# Draft",
      selectedText: "Draft",
      selectionStart: 2,
      selectionEnd: 7
    )

    let workflowInput = try XCTUnwrap(variables["workflowInput"] as? [String: Any])
    XCTAssertEqual(variables["noteRoot"] as? String, "/tmp/notes")
    XCTAssertEqual(workflowInput["noteId"] as? String, "note-1")
    XCTAssertEqual(workflowInput["bodyMarkdown"] as? String, "# Draft")
    XCTAssertEqual(workflowInput["selectedText"] as? String, "Draft")
    XCTAssertEqual(workflowInput["selectionStart"] as? Int, 2)
    XCTAssertEqual(workflowInput["selectionEnd"] as? Int, 7)
  }

  func testWorkflowRunArgumentsPassVariablesFileAndNoBodyOnArgv() {
    let arguments = rielaWorkflowRunArguments(
      workflowName: "note-edit-rewrite",
      workflowDefinitionDirectory: "/tmp/examples",
      variablesFilePath: "/tmp/riela-note-workflow/variables.json"
    )

    XCTAssertEqual(arguments, [
      "workflow",
      "run",
      "note-edit-rewrite",
      "--workflow-definition-dir",
      "/tmp/examples",
      "--variables-file",
      "/tmp/riela-note-workflow/variables.json",
      "--output",
      "jsonl"
    ])
    XCTAssertFalse(arguments.contains("--variables"))
  }

  func testWorkflowEditRewriteLargeBodySucceedsViaVariablesFile() throws {
    // A body far larger than ARG_MAX must not appear on argv; the workflow reads
    // it from the variables file instead. A fake `riela` echoes the file's size
    // as the rewrite so we can confirm the whole body was passed through.
    let executable = try makeVariablesFileEchoExecutable(function: #function)
    let hugeBody = String(repeating: "A", count: 4 * 1024 * 1024)

    let draft = try runNoteEditRewriteWorkflow(
      request: RielaNoteEditRewriteWorkflowRequest(
        executablePath: executable,
        workflowDefinitionDirectory: "/tmp/examples",
        noteId: "note-1",
        noteRoot: "/tmp/notes",
        instruction: "Improve",
        bodyMarkdown: hugeBody,
        selectedText: nil,
        selectionStart: nil,
        selectionEnd: nil,
        environment: ProcessInfo.processInfo.environment,
        deadlineSeconds: 30
      ),
      processBox: RielaWorkflowProcessBox()
    )

    XCTAssertTrue(draft.rewrittenMarkdown.contains("bytes="))
    let reportedBytes = draft.rewrittenMarkdown
      .components(separatedBy: "bytes=").last
      .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    // The variables file JSON must contain the full 4 MB body.
    XCTAssertNotNil(reportedBytes)
    XCTAssertGreaterThan(reportedBytes ?? 0, hugeBody.count)
  }

  func testWorkflowEditRewriteCancelBeforeLaunchSpawnsNoProcess() throws {
    let executable = try makeProcessMarkerExecutable(function: #function)
    let markerPath = executable + ".ran"
    let processBox = RielaWorkflowProcessBox()
    processBox.terminate() // cancel before the run begins

    XCTAssertThrowsError(try runNoteEditRewriteWorkflow(
      request: RielaNoteEditRewriteWorkflowRequest(
        executablePath: executable,
        workflowDefinitionDirectory: "/tmp/examples",
        noteId: "note-1",
        noteRoot: "/tmp/notes",
        instruction: "Improve",
        bodyMarkdown: "# Draft",
        selectedText: nil,
        selectionStart: nil,
        selectionEnd: nil,
        environment: ProcessInfo.processInfo.environment,
        deadlineSeconds: 30
      ),
      processBox: processBox
    )) { error in
      XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: markerPath),
      "cancelled run must not spawn the workflow process"
    )
  }

  func testWorkflowEditRewriteCancelMidRunYieldsCancellationError() throws {
    let executable = try makeSleepingExecutable(function: #function)
    let processBox = RielaWorkflowProcessBox()

    let runExpectation = expectation(description: "run returns")
    var caughtError: Error?
    Thread.detachNewThread {
      do {
        _ = try runNoteEditRewriteWorkflow(
          request: RielaNoteEditRewriteWorkflowRequest(
            executablePath: executable,
            workflowDefinitionDirectory: "/tmp/examples",
            noteId: "note-1",
            noteRoot: "/tmp/notes",
            instruction: "Improve",
            bodyMarkdown: "# Draft",
            selectedText: nil,
            selectionStart: nil,
            selectionEnd: nil,
            environment: ProcessInfo.processInfo.environment,
            deadlineSeconds: 30
          ),
          processBox: processBox
        )
      } catch {
        caughtError = error
      }
      runExpectation.fulfill()
    }
    // Let the process launch, then cancel mid-run.
    Thread.sleep(forTimeInterval: 0.3)
    processBox.terminate()

    wait(for: [runExpectation], timeout: 10)
    XCTAssertTrue(caughtError is CancellationError, "expected CancellationError, got \(String(describing: caughtError))")
  }

  func testWorkflowEditRewriteParserReadsLastDecodableRootOutputLine() {
    let output = """
    {"event":"progress"}
    {"result":{"rootOutput":{"rewrittenMarkdown":"first","summary":"ignored"}}}
    {"result":{"rootOutput":{"rewrittenMarkdown":"second","summary":"used"}}}
    """

    let draft = parseNoteEditRewriteDraft(from: output)

    XCTAssertEqual(draft, RielaNoteEditRewriteDraft(rewrittenMarkdown: "second", summary: "used"))
  }

  func testParseNoteEditRewriteDraftRejectsEmptyRewrittenMarkdown() {
    let output = """
    {"result":{"rootOutput":{"rewrittenMarkdown":"","summary":"refused"}}}
    """
    XCTAssertNil(parseNoteEditRewriteDraft(from: output))
  }

  func testParseNoteEditRewriteDraftRejectsWhitespaceRewrittenMarkdown() {
    let output = """
    {"result":{"rootOutput":{"rewrittenMarkdown":"   \\n\\t ","summary":"refused"}}}
    """
    XCTAssertNil(parseNoteEditRewriteDraft(from: output))
  }

  func testWorkflowEditRewriteDefaultProviderAcceptsTrustedAbsoluteEnvironmentOverrides() throws {
    let workflowDefinitionDirectory = try makeWorkflowDefinitionDirectoryFixture(function: "\(#function)-workflow")
    let executable = try makeExecutableFixture(function: "\(#function)-executable")

    let provider = try XCTUnwrap(RielaWorkflowNoteEditRewriteProvider.defaultProvider(environment: [
      "RIELA_NOTE_EDIT_REWRITE_WORKFLOW_DIR": workflowDefinitionDirectory,
      "RIELA_NOTE_EDIT_REWRITE_RIELA_EXECUTABLE": executable
    ]))

    XCTAssertEqual(provider.workflowDefinitionDirectory, workflowDefinitionDirectory)
    XCTAssertEqual(provider.executablePath, executable)
    XCTAssertTrue(provider.allowEnvironmentOverrides)

    let sharedExecutableProvider = try XCTUnwrap(RielaWorkflowNoteEditRewriteProvider.defaultProvider(environment: [
      "RIELA_NOTE_EDIT_REWRITE_WORKFLOW_DIR": workflowDefinitionDirectory,
      "RIELA_APP_RIELA_EXECUTABLE": executable
    ]))

    XCTAssertEqual(sharedExecutableProvider.workflowDefinitionDirectory, workflowDefinitionDirectory)
    XCTAssertEqual(sharedExecutableProvider.executablePath, executable)
    XCTAssertTrue(sharedExecutableProvider.allowEnvironmentOverrides)
  }

  func testWorkflowProviderSanitizesInheritedEnvironment() {
    let sanitized = rielaWorkflowSanitizedEnvironment(from: [
      "AWS_ACCESS_KEY_ID": "secret",
      "AWS_SECRET_ACCESS_KEY": "secret",
      "GITHUB_TOKEN": "secret",
      "RIELA_APP_RIELA_EXECUTABLE": "/tmp/riela",
      "PATH": "/usr/bin",
      "HOME": "/Users/test",
      "LC_CTYPE": "UTF-8"
    ])

    XCTAssertEqual(sanitized["PATH"], "/usr/bin")
    XCTAssertEqual(sanitized["HOME"], "/Users/test")
    XCTAssertEqual(sanitized["LC_CTYPE"], "UTF-8")
    // Genuinely unrelated/sensitive vars are still dropped.
    XCTAssertNil(sanitized["AWS_ACCESS_KEY_ID"])
    XCTAssertNil(sanitized["AWS_SECRET_ACCESS_KEY"])
    XCTAssertNil(sanitized["GITHUB_TOKEN"])
    XCTAssertNil(sanitized["RIELA_APP_RIELA_EXECUTABLE"])
  }

  func testWorkflowProviderPreservesModelAuthEnvironment() {
    // The spawned `riela workflow run` forwards these to its codex-agent node,
    // whose inner codex process derives env-based auth from this scrubbed
    // parent. They must survive sanitization for env-key users, or real
    // rewrites/link-proposals fail with workflowFailed.
    let modelAuthEnvironment = [
      "OPENAI_API_KEY": "openai",
      "OPENAI_BASE_URL": "https://openai.example",
      "ANTHROPIC_API_KEY": "anthropic",
      "ANTHROPIC_BASE_URL": "https://anthropic.example",
      "CLAUDE_API_KEY": "claude",
      "CLAUDE_CONFIG_DIR": "/Users/test/.claude",
      "CURSOR_API_KEY": "cursor",
      "CURSOR_AUTH_TOKEN": "cursor-token",
      "CURSOR_BASE_URL": "https://cursor.example",
      "CURSOR_CONFIG_DIR": "/Users/test/.cursor",
      "GEMINI_API_KEY": "gemini",
      "GEMINI_BASE_URL": "https://gemini.example",
      "GOOGLE_API_KEY": "google",
      "CODEX_HOME": "/Users/test/.codex",
      "RIELA_CODEX_AGENT_EXECUTABLE": "/usr/local/bin/codex",
      "RIELA_CLAUDE_CODE_AGENT_EXECUTABLE": "/usr/local/bin/claude",
      "RIELA_CURSOR_CLI_AGENT_EXECUTABLE": "/usr/local/bin/cursor-agent"
    ]
    let sanitized = rielaWorkflowSanitizedEnvironment(from: modelAuthEnvironment)

    for (key, value) in modelAuthEnvironment {
      XCTAssertEqual(sanitized[key], value, "expected model-auth var \(key) to survive sanitization")
    }
  }

  func testWorkflowProviderRejectsPathAndCurrentWorkingDirectoryFallbacks() throws {
    let fakeExecutable = try makeExecutableFixture(function: "\(#function)-executable")
    let workflowDefinitionDirectory = try makeWorkflowDefinitionDirectoryFixture(function: "\(#function)-workflow")

    XCTAssertNil(resolvedRielaExecutablePath("/usr/bin/env", environment: [:], allowEnvironmentOverrides: true))
    XCTAssertEqual(
      resolvedRielaExecutablePath(fakeExecutable, environment: [:], allowEnvironmentOverrides: false),
      fakeExecutable
    )

    let candidates = defaultWorkflowDirectoryCandidates(
      environment: ["RIELA_NOTE_EDIT_REWRITE_WORKFLOW_DIR": "examples"],
      workflowDirectoryEnvironmentName: "RIELA_NOTE_EDIT_REWRITE_WORKFLOW_DIR",
      allowEnvironmentOverrides: true
    )
    XCTAssertFalse(candidates.contains("examples"))
    XCTAssertFalse(candidates.contains(URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    ).appendingPathComponent("examples", isDirectory: true).path))

    XCTAssertNil(RielaWorkflowNoteEditRewriteProvider.defaultProvider(environment: [
      "RIELA_NOTE_EDIT_REWRITE_WORKFLOW_DIR": "examples",
      "RIELA_NOTE_EDIT_REWRITE_RIELA_EXECUTABLE": fakeExecutable,
      "PATH": URL(fileURLWithPath: fakeExecutable).deletingLastPathComponent().path
    ]))
    XCTAssertNil(RielaWorkflowNoteEditRewriteProvider.defaultProvider(environment: [
      "RIELA_NOTE_EDIT_REWRITE_WORKFLOW_DIR": workflowDefinitionDirectory,
      "PATH": URL(fileURLWithPath: fakeExecutable).deletingLastPathComponent().path
    ]))
  }
  #endif
}

#if os(macOS)
private func makeWorkflowDefinitionDirectoryFixture(function: String = #function) throws -> String {
  let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/RielaNoteEditRewriteTests", isDirectory: true)
    .appendingPathComponent(function, isDirectory: true)
    .appendingPathComponent("examples", isDirectory: true)
  if FileManager.default.fileExists(atPath: directory.path) {
    try FileManager.default.removeItem(at: directory)
  }
  let workflowDirectory = directory.appendingPathComponent("note-edit-rewrite", isDirectory: true)
  try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
  try "{}\n".write(
    to: workflowDirectory.appendingPathComponent("workflow.json"),
    atomically: true,
    encoding: .utf8
  )
  return directory.path
}

private func makeExecutableFixture(function: String = #function) throws -> String {
  let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/RielaNoteEditRewriteTests", isDirectory: true)
    .appendingPathComponent(function, isDirectory: true)
  if FileManager.default.fileExists(atPath: directory.path) {
    try FileManager.default.removeItem(at: directory)
  }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let executable = directory.appendingPathComponent("riela")
  try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
  return executable.path
}

private func makeScriptExecutable(function: String, script: String) throws -> String {
  let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/RielaNoteEditRewriteTests", isDirectory: true)
    .appendingPathComponent(function, isDirectory: true)
  if FileManager.default.fileExists(atPath: directory.path) {
    try FileManager.default.removeItem(at: directory)
  }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let executable = directory.appendingPathComponent("riela")
  try script.write(to: executable, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
  return executable.path
}

// Reads the `--variables-file` argument, reports its byte size, and emits a
// JSONL run-result line. The body is never on argv, so success proves it was
// read from the variables file.
private func makeVariablesFileEchoExecutable(function: String) throws -> String {
  try makeScriptExecutable(function: function, script: """
  #!/bin/sh
  file=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--variables-file" ]; then
      file="$2"
      shift 2
      continue
    fi
    shift
  done
  bytes=$(wc -c < "$file" | tr -d ' ')
  printf '{"result":{"rootOutput":{"rewrittenMarkdown":"bytes=%s","summary":"echo"}}}\\n' "$bytes"
  exit 0
  """)
}

// Touches a `<executable>.ran` marker file the moment it is invoked, so a test
// can assert whether the process was ever spawned.
private func makeProcessMarkerExecutable(function: String) throws -> String {
  try makeScriptExecutable(function: function, script: """
  #!/bin/sh
  : > "$0.ran"
  printf '{"result":{"rootOutput":{"rewrittenMarkdown":"ran","summary":"ran"}}}\\n'
  exit 0
  """)
}

// Sleeps long enough for a mid-run cancellation to terminate it by signal.
private func makeSleepingExecutable(function: String) throws -> String {
  try makeScriptExecutable(function: function, script: """
  #!/bin/sh
  sleep 30
  printf '{"result":{"rootOutput":{"rewrittenMarkdown":"late","summary":"late"}}}\\n'
  exit 0
  """)
}
#endif

private enum RewriteTestError: Error {
  case unsupported
}

private final class RewriteTestClient: RielaNoteUIClient, @unchecked Sendable {
  struct RewriteRequest: Equatable {
    var noteId: String
    var instruction: String
    var bodyMarkdown: String
    var selectedText: String?
    var selectionStart: Int?
    var selectionEnd: Int?
  }

  var rewriteRequests: [RewriteRequest] = []
  var rewriteDraft = RielaNoteEditRewriteDraft(rewrittenMarkdown: "# Rewritten\n\nBody", summary: "Rewritten")
  var rewriteError: Error?
  var rewriteDelayNanoseconds: UInt64?
  var updateNoteBodyCallCount = 0

  var defaultConfigWorkflowRoot: String {
    "tmp/RielaNoteEditRewriteTests/default-config-workflows"
  }

  func listNotebooks(limit: Int, offset: Int) async throws -> [Notebook] {
    []
  }

  func listNotes(notebookId: String, limit: Int, offset: Int) async throws -> [Note] {
    Array([note(noteId: "note-1"), note(noteId: "note-2")].dropFirst(offset).prefix(limit))
  }

  func listTags() async throws -> [Tag] {
    []
  }

  func createUserMemo(bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw RewriteTestError.unsupported
  }

  func searchNotes(
    query: String,
    tagFilter: [String],
    classFilter: [String],
    limit: Int,
    offset: Int
  ) async throws -> [NoteSearchResult] {
    []
  }

  func noteDetail(noteId: String) async throws -> RielaNoteDetail {
    RielaNoteDetail(note: note(noteId: noteId))
  }

  func firstNote(inNotebook notebookId: String) async throws -> RielaNoteDetail? {
    RielaNoteDetail(note: note(noteId: "note-1"))
  }

  func resolveFile(fileId: String) async throws -> RielaNoteResolvedFile {
    throw RewriteTestError.unsupported
  }

  func updateNoteBody(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    updateNoteBodyCallCount += 1
    return RielaNoteDetail(note: note(noteId: noteId, bodyMarkdown: bodyMarkdown))
  }

  func applyTag(noteId: String, tagName: String, classId: String?) async throws -> RielaNoteDetail {
    throw RewriteTestError.unsupported
  }

  func removeTag(noteId: String, tagName: String) async throws -> RielaNoteDetail {
    throw RewriteTestError.unsupported
  }

  func addComment(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw RewriteTestError.unsupported
  }

  func linkNote(noteId: String, targetNoteId: String, linkKind: String) async throws -> RielaNoteDetail {
    throw RewriteTestError.unsupported
  }

  func proposeNoteBodyRewrite(
    noteId: String,
    instruction: String,
    bodyMarkdown: String,
    selectedText: String?,
    selectionStart: Int?,
    selectionEnd: Int?
  ) async throws -> RielaNoteEditRewriteDraft {
    if let rewriteDelayNanoseconds {
      try await Task.sleep(nanoseconds: rewriteDelayNanoseconds)
    }
    rewriteRequests.append(RewriteRequest(
      noteId: noteId,
      instruction: instruction,
      bodyMarkdown: bodyMarkdown,
      selectedText: selectedText,
      selectionStart: selectionStart,
      selectionEnd: selectionEnd
    ))
    if let rewriteError {
      throw rewriteError
    }
    return rewriteDraft
  }

  func answerNoteAgentTurn(message: String, limit: Int) async throws -> RielaNoteAgentTurn {
    throw RewriteTestError.unsupported
  }

  func saveNoteAgentConversation(
    title: String,
    turns: [RielaNoteAgentTurn]
  ) async throws -> RielaNoteAgentConversationSaveResult {
    throw RewriteTestError.unsupported
  }

  func appendNoteAgentTurn(
    notebookId: String,
    turn: RielaNoteAgentTurn
  ) async throws -> RielaNoteAgentConversationSaveResult {
    throw RewriteTestError.unsupported
  }

  func proposeNoteConfigAgentChange(message: String) async throws -> RielaNoteConfigAgentProposal {
    throw RewriteTestError.unsupported
  }

  func applyNoteConfigAgentProposal(
    _ proposal: RielaNoteConfigAgentProposal,
    workflowRoot: String
  ) async throws -> RielaNoteConfigAgentApplyResult {
    throw RewriteTestError.unsupported
  }

  private func note(noteId: String, bodyMarkdown: String? = nil) -> Note {
    Note(
      noteId: noteId,
      notebookId: "notebook-1",
      noteNumber: noteId == "note-1" ? 1 : 2,
      title: noteId == "note-1" ? "Page One" : "Ontology",
      bodyMarkdown: bodyMarkdown ?? (noteId == "note-1" ? "# Page One\n\nBody" : "# Ontology\n\nSearch body"),
      readOnly: false,
      createdAt: "2026-07-04T00:00:00Z",
      updatedAt: "2026-07-04T00:00:00Z"
    )
  }
}

private final class CapturingEditRewriteProvider: RielaNoteEditRewriteProviding, @unchecked Sendable {
  struct Request: Equatable {
    var noteId: String
    var noteRoot: String
    var instruction: String
    var bodyMarkdown: String
    var selectedText: String?
    var selectionStart: Int?
    var selectionEnd: Int?
  }

  private let draft: RielaNoteEditRewriteDraft
  private(set) var requests: [Request] = []

  init(draft: RielaNoteEditRewriteDraft) {
    self.draft = draft
  }

  func proposeRewrite(
    noteId: String,
    noteRoot: String,
    instruction: String,
    bodyMarkdown: String,
    selectedText: String?,
    selectionStart: Int?,
    selectionEnd: Int?
  ) async throws -> RielaNoteEditRewriteDraft {
    requests.append(Request(
      noteId: noteId,
      noteRoot: noteRoot,
      instruction: instruction,
      bodyMarkdown: bodyMarkdown,
      selectedText: selectedText,
      selectionStart: selectionStart,
      selectionEnd: selectionEnd
    ))
    return draft
  }
}
