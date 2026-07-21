import Foundation
import RielaNote
@testable import RielaNoteUI
import XCTest

@MainActor
final class RielaNoteNotebookExpansionTests: XCTestCase {
  func testExpansionIsLazyReusesCacheInvalidatesAndLinksEverySource() async throws {
    let service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Plan",
      pages: [
        NotePageDraft(bodyMarkdown: "SOURCE-BODY-SENTINEL: Draft the milestone.", readOnly: false),
        NotePageDraft(bodyMarkdown: "Assign an owner.", readOnly: false)
      ]
    )
    let untouched = try service.createNotebook(title: "Never expanded")
    let provider = NotebookExpansionProviderStub()
    let client = NoteServiceRielaNoteUIClient(service: service, notebookExpansionProvider: provider)
    let viewModel = RielaNoteLibraryViewModel(client: client)

    XCTAssertNil(try service.getNotebook(untouched.notebookId).metaJSON)
    await viewModel.expandNotebook(source.notebook)
    let firstSession = try XCTUnwrap(viewModel.notebookExpansionSession)

    XCTAssertEqual(provider.compactRequests.count, 1)
    XCTAssertEqual(provider.compactRequests.first?.sourceNotes.map(\.bodyMarkdown), [
      "SOURCE-BODY-SENTINEL: Draft the milestone.",
      "Assign an owner."
    ])
    XCTAssertNotNil(try service.getNotebook(source.notebook.notebookId).metaJSON)
    XCTAssertNil(try service.getNotebook(untouched.notebookId).metaJSON)
    let seedLinks = try service.listLinks(noteId: firstSession.initialNoteId)
    XCTAssertEqual(Set(seedLinks.map(\.toNoteId)), Set(source.notes.map(\.noteId)))
    XCTAssertTrue(seedLinks.allSatisfy { $0.provenance == .ai && $0.linkKind == "source-citation" })

    await viewModel.expandNotebook(source.notebook)
    let secondSession = try XCTUnwrap(viewModel.notebookExpansionSession)
    XCTAssertEqual(provider.compactRequests.count, 1, "unchanged source must reuse compact cache")
    XCTAssertNotEqual(secondSession.conversationNotebookId, firstSession.conversationNotebookId)

    _ = try service.updateNoteBody(
      noteId: source.notes[0].noteId,
      bodyMarkdown: "SOURCE-BODY-SENTINEL: Revised milestone."
    )
    await viewModel.expandNotebook(source.notebook)
    XCTAssertEqual(provider.compactRequests.count, 2, "updatedAt change must invalidate cache")

    _ = try service.createNote(
      notebookId: source.notebook.notebookId,
      bodyMarkdown: "A newly added source note."
    )
    await viewModel.expandNotebook(source.notebook)
    XCTAssertEqual(provider.compactRequests.count, 3, "note-count change must invalidate cache")
    XCTAssertEqual(viewModel.notebookExpansionSession?.sourceNoteIds.count, 3)
  }

  func testMissingProviderFailsBeforeCacheOrConversationMutation() async throws {
    let service = try makeService()
    let source = try service.createNote(bodyMarkdown: "# Source\nBody")
    let beforeNotebookCount = try service.listNotebooks(limit: 100).count
    let viewModel = RielaNoteLibraryViewModel(client: NoteServiceRielaNoteUIClient(service: service))

    await viewModel.expandNotebook(try service.getNotebook(source.notebookId))

    XCTAssertNil(viewModel.notebookExpansionSession)
    XCTAssertNotNil(viewModel.notebookExpansionError)
    XCTAssertNil(try service.getNotebook(source.notebookId).metaJSON)
    XCTAssertEqual(try service.listNotebooks(limit: 100).count, beforeNotebookCount)

    let configuredProvider = NotebookExpansionProviderStub()
    let configuredViewModel = RielaNoteLibraryViewModel(client: NoteServiceRielaNoteUIClient(
      service: service,
      notebookExpansionProvider: configuredProvider
    ))
    await configuredViewModel.expandNotebook(try service.getNotebook(source.notebookId))
    let cachedMetadata = try XCTUnwrap(service.getNotebook(source.notebookId).metaJSON)
    let cachedNotebookCount = try service.listNotebooks(limit: 100).count
    let cachedSourceNoteCount = try service.listNotes(notebookId: source.notebookId, limit: 100).count
    let cacheHitViewModel = RielaNoteLibraryViewModel(client: NoteServiceRielaNoteUIClient(service: service))

    await cacheHitViewModel.expandNotebook(try service.getNotebook(source.notebookId))

    XCTAssertNil(cacheHitViewModel.notebookExpansionSession)
    XCTAssertNotNil(cacheHitViewModel.notebookExpansionError)
    XCTAssertEqual(try service.getNotebook(source.notebookId).metaJSON, cachedMetadata)
    XCTAssertEqual(try service.listNotebooks(limit: 100).count, cachedNotebookCount)
    XCTAssertEqual(
      try service.listNotes(notebookId: source.notebookId, limit: 100).count,
      cachedSourceNoteCount
    )
  }

  func testMalformedCacheIsMissAndStaleSnapshotRetriesOnce() async throws {
    let service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Plan",
      metaJSON: #"{"rielaNote":{"notebookCompact":[]}}"#,
      pages: [NotePageDraft(bodyMarkdown: "Initial body", readOnly: false)]
    )
    let provider = NotebookExpansionProviderStub()
    provider.onCompact = { callCount in
      if callCount == 1 {
        _ = try service.createNote(
          notebookId: source.notebook.notebookId,
          bodyMarkdown: "Added during first compaction"
        )
      }
    }
    let viewModel = RielaNoteLibraryViewModel(client: NoteServiceRielaNoteUIClient(
      service: service,
      notebookExpansionProvider: provider
    ))

    await viewModel.expandNotebook(source.notebook)

    XCTAssertEqual(provider.compactRequests.count, 2)
    XCTAssertNotNil(viewModel.notebookExpansionSession)
    XCTAssertNotNil(notebookCompactCache(from: try service.getNotebook(source.notebook.notebookId).metaJSON))
  }

  func testSecondStaleSnapshotFailsWithoutCacheOrConversationMutation() async throws {
    let service = try makeService()
    let source = try service.createNote(bodyMarkdown: "Initial body")
    let provider = NotebookExpansionProviderStub()
    provider.onCompact = { callCount in
      _ = try service.createNote(
        notebookId: source.notebookId,
        bodyMarkdown: "Added during compaction \(callCount)"
      )
    }
    let viewModel = RielaNoteLibraryViewModel(client: NoteServiceRielaNoteUIClient(
      service: service,
      notebookExpansionProvider: provider
    ))

    await viewModel.expandNotebook(try service.getNotebook(source.notebookId))

    XCTAssertEqual(provider.compactRequests.count, 2)
    XCTAssertNil(viewModel.notebookExpansionSession)
    XCTAssertNotNil(viewModel.notebookExpansionError)
    XCTAssertNil(try service.getNotebook(source.notebookId).metaJSON)
    XCTAssertEqual(try service.listNotebooks(limit: 100).count, 1)
  }

  func testSameNotebookExpansionIsSingleFlight() async throws {
    let service = try makeService()
    let source = try service.createNote(bodyMarkdown: "# Source\nBody")
    let provider = NotebookExpansionProviderStub()
    provider.compactDelayNanoseconds = 40_000_000
    let viewModel = RielaNoteLibraryViewModel(client: NoteServiceRielaNoteUIClient(
      service: service,
      notebookExpansionProvider: provider
    ))
    let notebook = try service.getNotebook(source.notebookId)

    let first = Task { await viewModel.expandNotebook(notebook) }
    try await Task.sleep(nanoseconds: 5_000_000)
    var duplicateCompleted = false
    let duplicate = Task { @MainActor in
      await viewModel.expandNotebook(notebook)
      duplicateCompleted = true
    }
    try await Task.sleep(nanoseconds: 10_000_000)
    XCTAssertFalse(duplicateCompleted)
    XCTAssertTrue(viewModel.isExpandingNotebook(notebook.notebookId))
    await first.value
    await duplicate.value

    XCTAssertEqual(provider.compactRequests.count, 1)
    XCTAssertEqual(try service.listNotebooks(limit: 100).count, 2)
  }

  func testExpansionAgentUsesSummaryOnlyAndPersistsLinkedTurn() async throws {
    let service = try makeService()
    let source = try service.createNote(bodyMarkdown: "SOURCE-BODY-SENTINEL: private body")
    let provider = NotebookExpansionProviderStub()
    let client = NoteServiceRielaNoteUIClient(service: service, notebookExpansionProvider: provider)
    let library = RielaNoteLibraryViewModel(client: client)
    await library.expandNotebook(try service.getNotebook(source.notebookId))
    let session = try XCTUnwrap(library.notebookExpansionSession)
    let agent = RielaNoteAgentViewModel(client: client)

    agent.beginNotebookExpansionSession(session)
    agent.draftMessage = "What is next?"
    await agent.submitDraft()

    XCTAssertEqual(provider.answerRequests, [RielaNoteNotebookExpansionRequest(
      compactSummaryMarkdown: "- Draft the milestone.\n- Assign an owner.",
      questionMarkdown: "What is next?"
    )])
    XCTAssertFalse(provider.answerRequests.description.contains("SOURCE-BODY-SENTINEL"))
    XCTAssertEqual(agent.turns.count, 2)
    let persistedId = try XCTUnwrap(agent.turns.last?.persistedNoteIds.first)
    let links = try service.listLinks(noteId: persistedId)
    XCTAssertEqual(links.map(\.toNoteId), [source.noteId])
    XCTAssertTrue(links.allSatisfy { $0.provenance == .ai })
  }

  func testExpansionAgentShowsAnswerWhenSourceDeletedMidSession() async throws {
    let service = try makeService()
    let source = try service.createNote(bodyMarkdown: "SOURCE-BODY")
    let provider = NotebookExpansionProviderStub()
    let client = NoteServiceRielaNoteUIClient(service: service, notebookExpansionProvider: provider)
    let library = RielaNoteLibraryViewModel(client: client)
    await library.expandNotebook(try service.getNotebook(source.notebookId))
    let session = try XCTUnwrap(library.notebookExpansionSession)
    let agent = RielaNoteAgentViewModel(client: client)
    agent.beginNotebookExpansionSession(session)

    // The source note this session was compacted from is deleted after the
    // session started, so persisting the turn's frozen source links throws.
    try service.deleteNote(noteId: source.noteId)

    agent.draftMessage = "What is next?"
    await agent.submitDraft()

    // Show-first: the paid-for answer stays visible (unsaved) instead of being
    // silently discarded, and the conversation is not wedged.
    XCTAssertEqual(agent.turns.count, 2)
    XCTAssertEqual(agent.turns.last?.assistantMarkdown, "Draft it, then assign an owner.")
    XCTAssertEqual(agent.turns.last?.persistedNoteIds, [])
    XCTAssertEqual(agent.state, .failed("Couldn't complete the agent turn. Please try again."))
  }

  func testExpansionAgentBypassesGeneralProviderAndExplicitNewConversationExitsMode() async throws {
    let client = AgentStubClient()
    let agent = RielaNoteAgentViewModel(client: client)
    let session = expansionSession()

    agent.beginNotebookExpansionSession(session)
    agent.draftMessage = "What is next?"
    await agent.submitDraft()

    XCTAssertEqual(client.generalAnswerCallCount, 0)
    XCTAssertEqual(client.expansionAnswerRequests.count, 1)
    XCTAssertEqual(client.appendedExpansionNotebookIds, [session.conversationNotebookId])
    agent.startNewConversation()
    XCTAssertEqual(agent.mode, .general)

    agent.draftMessage = "General question"
    await agent.submitDraft()
    XCTAssertEqual(client.generalAnswerCallCount, 1)
  }

  func testExpansionAgentSurfacesNotConfiguredAfterSessionStarts() async {
    let client = AgentStubClient()
    client.expansionAnswerError = RielaNoteNotebookExpansionError.notConfigured
    let agent = RielaNoteAgentViewModel(client: client)
    agent.beginNotebookExpansionSession(expansionSession())
    agent.draftMessage = "What is next?"

    await agent.submitDraft()

    XCTAssertEqual(agent.turns.count, 1)
    XCTAssertEqual(agent.state, .failed("Couldn't complete the agent turn. Please try again."))
    XCTAssertEqual(client.appendedExpansionNotebookIds, [])
  }

  func testBothNotebookSurfacesDispatchSharedExpansionAction() async throws {
    let service = try makeService()
    let source = try service.createNote(bodyMarkdown: "Source")
    let provider = NotebookExpansionProviderStub()
    let viewModel = RielaNoteLibraryViewModel(client: NoteServiceRielaNoteUIClient(
      service: service,
      notebookExpansionProvider: provider
    ))
    let notebook = try service.getNotebook(source.notebookId)

    await rielaNoteNotebookListExpandAction(viewModel: viewModel, notebook: notebook)
    await rielaNoteFileTreeExpandAction(viewModel: viewModel, notebook: notebook)

    XCTAssertEqual(provider.compactRequests.count, 1)
    XCTAssertEqual(try service.listNotebooks(limit: 100).count, 3)
  }

  #if os(macOS)
  func testAnswerVariablesCannotSerializeSourceBodies() throws {
    let variables = noteNotebookExpansionAnswerVariables(
      noteRoot: "/tmp/notes",
      request: RielaNoteNotebookExpansionRequest(
        compactSummaryMarkdown: "SUMMARY-SENTINEL",
        questionMarkdown: "What is next?"
      )
    )
    let data = try JSONSerialization.data(withJSONObject: variables, options: [.sortedKeys])
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))

    XCTAssertTrue(json.contains("SUMMARY-SENTINEL"))
    XCTAssertFalse(json.contains("SOURCE-BODY-SENTINEL"))
    XCTAssertFalse(json.contains("sourceNotes"))
    XCTAssertFalse(json.contains("notebookId"))
  }

  func testCompactVariablesSerializeSourceBodyOnlyThroughVariablesFile() throws {
    let variables = noteNotebookCompactVariables(
      noteRoot: "/tmp/notes",
      request: RielaNoteNotebookCompactRequest(
        notebookId: "notebook-1",
        notebookTitle: "Plan",
        sourceNotes: [RielaNoteNotebookCompactSourceNote(
          noteId: "note-1",
          noteNumber: 1,
          bodyMarkdown: "SOURCE-BODY-SENTINEL"
        )]
      )
    )
    let data = try JSONSerialization.data(withJSONObject: variables, options: [.sortedKeys])
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    let arguments = rielaWorkflowRunArguments(
      workflowName: "note-notebook-compact",
      workflowDefinitionDirectory: "/tmp/examples",
      variablesFilePath: "/tmp/private-variables.json"
    )

    XCTAssertTrue(json.contains("SOURCE-BODY-SENTINEL"))
    XCTAssertFalse(arguments.contains(where: { $0.contains("SOURCE-BODY-SENTINEL") }))
    XCTAssertEqual(arguments.suffix(3), ["/tmp/private-variables.json", "--output", "jsonl"])
  }

  func testNotebookCompactDefaultProviderDiscoversConfiguredBundle() throws {
    let repositoryRoot = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    )
    let executable = repositoryRoot
      .appendingPathComponent(".build/arm64-apple-macosx/debug/riela")
      .path
    let examples = repositoryRoot.appendingPathComponent("examples", isDirectory: true).path

    XCTAssertNotNil(RielaNoteWorkflowNotebookCompactProvider.defaultProvider(environment: [
      "RIELA_NOTE_NOTEBOOK_COMPACT_RIELA_EXECUTABLE": executable,
      "RIELA_NOTE_NOTEBOOK_COMPACT_WORKFLOW_DIR": examples
    ]))
  }

  func testNotebookCompactRunnerReadsLastJSONLAndCleansVariablesFile() throws {
    let fixture = try makeNotebookCompactExecutable(
      function: #function,
      scriptBody: """
      variables_file=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--variables-file" ]; then
          variables_file="$2"
          shift 2
          continue
        fi
        shift
      done
      printf '%s' "$variables_file" > "$0.variables-path"
      printf '{"event":"progress"}\n'
      printf '{"result":{"rootOutput":{"summaryMarkdown":"first","version":1}}}\n'
      printf '{"result":{"rootOutput":{"summaryMarkdown":"last","version":1}}}\n'
      """
    )

    let draft: RielaNoteNotebookCompactDraft = try runNoteNotebookCompactWorkflow(
      request: notebookCompactWorkflowRequest(executablePath: fixture),
      processBox: RielaWorkflowProcessBox(),
      outputType: RielaNoteNotebookCompactDraft.self
    )

    XCTAssertEqual(draft, RielaNoteNotebookCompactDraft(summaryMarkdown: "last", version: 1))
    let variablesPath = try String(contentsOfFile: "\(fixture).variables-path", encoding: .utf8)
    XCTAssertFalse(FileManager.default.fileExists(atPath: variablesPath))
  }

  func testNotebookCompactRunnerMapsFailureAndTimeout() throws {
    let failing = try makeNotebookCompactExecutable(
      function: "\(#function)-failure",
      scriptBody: "printf 'fixture failed' >&2\nexit 7"
    )
    XCTAssertThrowsError(try runNotebookCompactFixture(executablePath: failing)) { error in
      XCTAssertEqual(error as? RielaNoteNotebookExpansionError, .workflowFailed("fixture failed"))
    }

    let sleeping = try makeNotebookCompactExecutable(
      function: "\(#function)-timeout",
      scriptBody: "exec sleep 5"
    )
    XCTAssertThrowsError(try runNotebookCompactFixture(
      executablePath: sleeping,
      deadlineSeconds: 0.01
    )) { error in
      XCTAssertEqual(error as? RielaNoteNotebookExpansionError, .timedOut)
    }
  }

  func testNotebookCompactRunnerCancellationBeforeLaunchSpawnsNoProcess() throws {
    let executable = try makeNotebookCompactExecutable(
      function: #function,
      scriptBody: ": > \"$0.ran\""
    )
    let processBox = RielaWorkflowProcessBox()
    processBox.terminate()

    XCTAssertThrowsError(try runNotebookCompactFixture(
      executablePath: executable,
      processBox: processBox
    )) { error in
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: "\(executable).ran"))
  }

  func testNotebookCompactProviderSanitizesInheritedEnvironment() async throws {
    let executable = try makeNotebookCompactExecutable(
      function: #function,
      scriptBody: """
      if [ -n "$GITHUB_TOKEN" ] || [ "$OPENAI_API_KEY" != "model-auth" ]; then
        summary="leaked"
      else
        summary="sanitized"
      fi
      printf '{"result":{"rootOutput":{"summaryMarkdown":"%s","version":1}}}\n' "$summary"
      """
    )
    let provider = RielaNoteWorkflowNotebookCompactProvider(
      workflowDefinitionDirectory: "/tmp/examples",
      executablePath: executable,
      environment: [
        "GITHUB_TOKEN": "must-not-reach-child",
        "OPENAI_API_KEY": "model-auth",
        "PATH": "/usr/bin:/bin",
        "HOME": "/tmp"
      ]
    )

    let draft = try await provider.compactNotebook(
      noteRoot: "/tmp/notes",
      request: RielaNoteNotebookCompactRequest(
        notebookId: "notebook-1",
        notebookTitle: "Plan",
        sourceNotes: []
      )
    )

    XCTAssertEqual(draft.summaryMarkdown, "sanitized")
  }

  func testNotebookCompactProviderCancellationTerminatesRunningProcess() async throws {
    let executable = try makeNotebookCompactExecutable(
      function: #function,
      scriptBody: ": > \"$0.ran\"\nexec sleep 30"
    )
    let provider = RielaNoteWorkflowNotebookCompactProvider(
      workflowDefinitionDirectory: "/tmp/examples",
      executablePath: executable,
      environment: ["PATH": "/usr/bin:/bin"]
    )
    let task = Task {
      try await provider.compactNotebook(
        noteRoot: "/tmp/notes",
        request: RielaNoteNotebookCompactRequest(
          notebookId: "notebook-1",
          notebookTitle: "Plan",
          sourceNotes: []
        )
      )
    }
    let markerPath = "\(executable).ran"
    for _ in 0..<40 where !FileManager.default.fileExists(atPath: markerPath) {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: markerPath))
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
  }
  #endif
}

private func expansionSession() -> RielaNoteNotebookExpansionSession {
  RielaNoteNotebookExpansionSession(
    sourceNotebookId: "source-notebook",
    conversationNotebookId: "conversation-notebook",
    initialNoteId: "seed-note",
    compactSummaryMarkdown: "- Summary",
    sourceNoteIds: ["source-note"],
    sourceMarker: RielaNoteNotebookExpansionSourceMarker(updatedAt: "marker", noteCount: 1)
  )
}

#if os(macOS)
private func makeNotebookCompactExecutable(function: String, scriptBody: String) throws -> String {
  let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/RielaNoteNotebookExpansionTests", isDirectory: true)
    .appendingPathComponent(function, isDirectory: true)
  if FileManager.default.fileExists(atPath: directory.path) {
    try FileManager.default.removeItem(at: directory)
  }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let executable = directory.appendingPathComponent("riela")
  try "#!/bin/sh\n\(scriptBody)\n".write(to: executable, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
  return executable.path
}

private func notebookCompactWorkflowRequest(
  executablePath: String,
  deadlineSeconds: TimeInterval = 30
) -> RielaNoteNotebookCompactWorkflowRequest {
  RielaNoteNotebookCompactWorkflowRequest(
    executablePath: executablePath,
    workflowDefinitionDirectory: "/tmp/examples",
    variables: ["noteRoot": "/tmp/notes", "workflowInput": ["operation": "compact"]],
    environment: ["PATH": "/usr/bin:/bin"],
    deadlineSeconds: deadlineSeconds
  )
}

@discardableResult
private func runNotebookCompactFixture(
  executablePath: String,
  deadlineSeconds: TimeInterval = 30,
  processBox: RielaWorkflowProcessBox = RielaWorkflowProcessBox()
) throws -> RielaNoteNotebookCompactDraft {
  try runNoteNotebookCompactWorkflow(
    request: notebookCompactWorkflowRequest(
      executablePath: executablePath,
      deadlineSeconds: deadlineSeconds
    ),
    processBox: processBox,
    outputType: RielaNoteNotebookCompactDraft.self
  )
}
#endif

private final class NotebookExpansionProviderStub: RielaNoteNotebookExpansionProviding, @unchecked Sendable {
  var compactRequests: [RielaNoteNotebookCompactRequest] = []
  var answerRequests: [RielaNoteNotebookExpansionRequest] = []
  var compactDelayNanoseconds: UInt64 = 0
  var onCompact: ((Int) throws -> Void)?

  func compactNotebook(
    noteRoot: String,
    request: RielaNoteNotebookCompactRequest
  ) async throws -> RielaNoteNotebookCompactDraft {
    if compactDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: compactDelayNanoseconds)
    }
    compactRequests.append(request)
    try onCompact?(compactRequests.count)
    return RielaNoteNotebookCompactDraft(
      summaryMarkdown: "- Draft the milestone.\n- Assign an owner.",
      version: 1
    )
  }

  func answerNotebookExpansion(
    noteRoot: String,
    request: RielaNoteNotebookExpansionRequest
  ) async throws -> RielaNoteNotebookExpansionAnswer {
    answerRequests.append(request)
    return RielaNoteNotebookExpansionAnswer(assistantMarkdown: "Draft it, then assign an owner.")
  }
}
