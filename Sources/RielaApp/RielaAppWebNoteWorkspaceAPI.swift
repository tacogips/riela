#if os(macOS)
import Foundation
import RielaCore
import RielaGraphQL
import RielaNote
import RielaNoteWorkspace
import RielaServer

private struct RielaAppWebNoteProfileBody: Decodable {
  var expectedProfile: String?
}

private struct RielaAppWebNoteBodyMarkdownRequest: Decodable {
  var expectedProfile: String?
  var bodyMarkdown: String
}

private struct RielaAppWebNoteCommentRequest: Decodable {
  var expectedProfile: String?
  var bodyMarkdown: String
  var author: String?
}

private struct RielaAppWebNoteLinkRequest: Decodable {
  var expectedProfile: String?
  var targetNoteId: String
  var linkKind: String
}

private struct RielaAppWebNoteRewriteRequest: Decodable {
  var expectedProfile: String?
  var instruction: String
  var bodyMarkdown: String
  var selectedText: String?
  var selectionStart: Int?
  var selectionEnd: Int?
}

private struct RielaAppWebNoteSelectionQuestionRequest: Decodable {
  var expectedProfile: String?
  var question: String
  var bodyMarkdown: String
  var selectedText: String
  var selectionStart: Int
  var selectionEnd: Int
}

private struct RielaAppWebNoteAgentTurnRequest: Decodable {
  var expectedProfile: String?
  var message: String
  var limit: Int?
}

private struct RielaAppWebNoteAgentTurnPayload: Codable {
  var userMarkdown: String
  var assistantMarkdown: String
  var citations: [RielaNoteAgentCitation]

  init(turn: RielaNoteAgentTurn) {
    userMarkdown = turn.userMarkdown
    assistantMarkdown = turn.assistantMarkdown
    citations = turn.citations
  }

  var turn: RielaNoteAgentTurn {
    RielaNoteAgentTurn(
      userMarkdown: userMarkdown,
      assistantMarkdown: assistantMarkdown,
      citations: citations
    )
  }
}

private struct RielaAppWebNoteAgentConversationRequest: Decodable {
  var expectedProfile: String?
  var title: String
  var turns: [RielaAppWebNoteAgentTurnPayload]
}

private struct RielaAppWebNoteAgentAppendRequest: Decodable {
  var expectedProfile: String?
  var turn: RielaAppWebNoteAgentTurnPayload
}

private struct RielaAppWebNoteConfigProposalRequest: Decodable {
  var expectedProfile: String?
  var message: String
}

private struct RielaAppWebNoteConfigProposalPayload: Codable {
  var requestMarkdown: String
  var assistantMarkdown: String
  var tagClass: RielaNoteConfigTagClassDraft
  var tag: RielaNoteConfigTagDraft
  var autoAction: RielaNoteConfigAutoActionDraft
  var ingestionWorkflow: RielaNoteConfigIngestionWorkflowDraft

  init(proposal: RielaNoteConfigAgentProposal) {
    requestMarkdown = proposal.requestMarkdown
    assistantMarkdown = proposal.assistantMarkdown
    tagClass = proposal.tagClass
    tag = proposal.tag
    autoAction = proposal.autoAction
    ingestionWorkflow = proposal.ingestionWorkflow
  }

  var proposal: RielaNoteConfigAgentProposal {
    RielaNoteConfigAgentProposal(
      requestMarkdown: requestMarkdown,
      assistantMarkdown: assistantMarkdown,
      tagClass: tagClass,
      tag: tag,
      autoAction: autoAction,
      ingestionWorkflow: ingestionWorkflow
    )
  }
}

private struct RielaAppWebNoteConfigApplyRequest: Decodable {
  var expectedProfile: String?
  var proposal: RielaAppWebNoteConfigProposalPayload
}

private struct RielaAppWebNoteExpansionAnswerRequest: Decodable {
  var expectedProfile: String?
  var compactSummaryMarkdown: String
  var questionMarkdown: String
}

private struct RielaAppWebNoteExpansionAppendRequest: Decodable {
  var expectedProfile: String?
  var turnId: String
  var questionMarkdown: String
  var assistantMarkdown: String
  var sourceNoteIds: [String]
}

extension RielaApp {
  func webNoteWorkspaceResponse(
    components: [String],
    request: RielaHTTPRequest
  ) async -> RielaHTTPResponse? {
    guard components.count >= 4, components[0...2] == ["api", "v1", "notes"] else {
      return nil
    }
    let tail = Array(components[3...]).compactMap(\.removingPercentEncoding)
    guard tail.count == components.count - 3 else {
      return webNoteWorkspaceError(status: 400, code: "invalid_request", message: "Malformed path")
    }
    do {
      switch (request.method, tail.first ?? "") {
      case ("GET", "files") where tail.count == 2:
        return try await webNoteFileResponse(fileId: tail[1])
      case ("POST", "memos") where tail.count == 1:
        let body: RielaAppWebNoteBodyMarkdownRequest = try webNoteBody(request)
        if let conflict = webNoteWorkspaceProfileConflict(body.expectedProfile) { return conflict }
        return try await webNoteDetailJSON(webNoteWorkspaceClient().createUserMemo(bodyMarkdown: body.bodyMarkdown))
      case ("POST", "agent") where tail.count >= 2:
        return try await webNoteAgentResponse(tail: tail, request: request)
      case ("POST", "config-agent") where tail.count == 2:
        return try await webNoteConfigAgentResponse(action: tail[1], request: request)
      case ("GET", "notebooks") where tail.count == 3 && tail[2] == "first-note":
        let detail = try await webNoteWorkspaceClient().firstNote(inNotebook: tail[1])
        return webNoteWorkspaceJSON(["detail": try detail.map(webNoteDetailValue) ?? .null])
      case ("POST", "notebooks") where tail.count == 3 && tail[2] == "notes":
        let body: RielaAppWebNoteBodyMarkdownRequest = try webNoteBody(request)
        if let conflict = webNoteWorkspaceProfileConflict(body.expectedProfile) { return conflict }
        return try await webNoteDetailJSON(
          webNoteWorkspaceClient().createNote(inNotebook: tail[1], bodyMarkdown: body.bodyMarkdown)
        )
      case ("POST", "notebooks") where tail.count == 4 && tail[2] == "expansion":
        return try await webNoteExpansionResponse(notebookId: tail[1], action: tail[3], request: request)
      case ("GET", _) where tail.count == 2 && tail[1] == "detail":
        return try await webNoteDetailJSON(webNoteWorkspaceClient().noteDetail(noteId: tail[0]))
      case ("GET", _) where tail.count == 2 && tail[1] == "window":
        let pageSize = webNoteQueryInt(request.query, name: "pageSize") ?? 20
        let window = try await webNoteWorkspaceClient().notebookNotesWindow(
          containing: tail[0],
          pageSize: max(1, min(pageSize, 200))
        )
        return webNoteWorkspaceJSON([
          "notes": .array(try window.notes.map { try webNoteEncoded(GraphQLNoteDTO(note: $0)) }),
          "startOffset": .number(Double(window.startOffset)),
          "hasEarlierNotes": .bool(window.hasEarlierNotes),
          "hasMoreNotes": .bool(window.hasMoreNotes)
        ])
      case ("POST", _) where tail.count == 2 && tail[1] == "body":
        let body: RielaAppWebNoteBodyMarkdownRequest = try webNoteBody(request)
        if let conflict = webNoteWorkspaceProfileConflict(body.expectedProfile) { return conflict }
        return try await webNoteDetailJSON(
          webNoteWorkspaceClient().updateNoteBody(noteId: tail[0], bodyMarkdown: body.bodyMarkdown)
        )
      case ("POST", _) where tail.count == 2 && tail[1] == "comments":
        let body: RielaAppWebNoteCommentRequest = try webNoteBody(request)
        if let conflict = webNoteWorkspaceProfileConflict(body.expectedProfile) { return conflict }
        let client = try webNoteWorkspaceClient()
        let detail: RielaNoteDetail
        if let author = body.author {
          detail = try await client.addComment(noteId: tail[0], bodyMarkdown: body.bodyMarkdown, author: author)
        } else {
          detail = try await client.addComment(noteId: tail[0], bodyMarkdown: body.bodyMarkdown)
        }
        return try webNoteDetailJSON(detail)
      case ("POST", _) where tail.count == 4 && tail[1] == "comments" && tail[3] == "promote":
        let body: RielaAppWebNoteProfileBody = try webNoteBody(request)
        if let conflict = webNoteWorkspaceProfileConflict(body.expectedProfile) { return conflict }
        return try await webNoteDetailJSON(
          webNoteWorkspaceClient().promoteCommentToNotebook(noteId: tail[0], commentId: tail[2])
        )
      case ("POST", _) where tail.count == 2 && tail[1] == "links":
        let body: RielaAppWebNoteLinkRequest = try webNoteBody(request)
        if let conflict = webNoteWorkspaceProfileConflict(body.expectedProfile) { return conflict }
        return try await webNoteDetailJSON(webNoteWorkspaceClient().linkNote(
          noteId: tail[0],
          targetNoteId: body.targetNoteId,
          linkKind: body.linkKind
        ))
      case ("POST", _) where tail.count == 2 && tail[1] == "link-proposals":
        let body: RielaAppWebNoteProfileBody = try webNoteBody(request)
        if let conflict = webNoteWorkspaceProfileConflict(body.expectedProfile) { return conflict }
        let proposals = try await webNoteWorkspaceClient().proposeNoteLinks(noteId: tail[0])
        return webNoteWorkspaceJSON([
          "proposals": .array(try proposals.map { try webNoteEncoded(GraphQLNoteLinkProposalDTO(proposal: $0)) })
        ])
      case ("POST", _) where tail.count == 2 && tail[1] == "rewrite":
        let body: RielaAppWebNoteRewriteRequest = try webNoteBody(request)
        if let conflict = webNoteWorkspaceProfileConflict(body.expectedProfile) { return conflict }
        let draft = try await webNoteWorkspaceClient().proposeNoteBodyRewrite(
          noteId: tail[0],
          instruction: body.instruction,
          bodyMarkdown: body.bodyMarkdown,
          selectedText: body.selectedText,
          selectionStart: body.selectionStart,
          selectionEnd: body.selectionEnd
        )
        return try webNoteWorkspaceJSON(["draft": webNoteEncoded(draft)])
      case ("POST", _) where tail.count == 2 && tail[1] == "selection-question":
        let body: RielaAppWebNoteSelectionQuestionRequest = try webNoteBody(request)
        if let conflict = webNoteWorkspaceProfileConflict(body.expectedProfile) { return conflict }
        let draft = try await webNoteWorkspaceClient().answerNoteSelectionQuestion(
          noteId: tail[0],
          question: body.question,
          bodyMarkdown: body.bodyMarkdown,
          selectedText: body.selectedText,
          selectionStart: body.selectionStart,
          selectionEnd: body.selectionEnd
        )
        return try webNoteWorkspaceJSON(["draft": webNoteEncoded(draft)])
      default:
        return webNoteWorkspaceError(status: 404, code: "not_found", message: "Unknown notes API route")
      }
    } catch let error as RielaAppWebNoteDecodeError {
      return webNoteWorkspaceError(status: 400, code: "invalid_request", message: error.message)
    } catch {
      return webNoteWorkspaceFailure(error)
    }
  }

  private func webNoteAgentResponse(
    tail: [String],
    request: RielaHTTPRequest
  ) async throws -> RielaHTTPResponse {
    let client = try webNoteWorkspaceClient()
    switch tail[1] {
    case "turns" where tail.count == 2:
      let body: RielaAppWebNoteAgentTurnRequest = try webNoteBody(request)
      if let conflict = webNoteWorkspaceProfileConflict(body.expectedProfile) { return conflict }
      let turn = try await client.answerNoteAgentTurn(
        message: body.message,
        limit: max(1, min(body.limit ?? 6, 20))
      )
      return try webNoteWorkspaceJSON(["turn": webNoteEncoded(RielaAppWebNoteAgentTurnPayload(turn: turn))])
    case "conversations" where tail.count == 2:
      let body: RielaAppWebNoteAgentConversationRequest = try webNoteBody(request)
      if let conflict = webNoteWorkspaceProfileConflict(body.expectedProfile) { return conflict }
      let saved = try await client.saveNoteAgentConversation(
        title: body.title,
        turns: body.turns.map(\.turn)
      )
      return webNoteWorkspaceJSON([
        "notebookId": .string(saved.notebookId),
        "noteIds": .array(saved.noteIds.map(JSONValue.string))
      ])
    case "conversations" where tail.count == 4 && tail[3] == "turns":
      let body: RielaAppWebNoteAgentAppendRequest = try webNoteBody(request)
      if let conflict = webNoteWorkspaceProfileConflict(body.expectedProfile) { return conflict }
      let saved = try await client.appendNoteAgentTurn(notebookId: tail[2], turn: body.turn.turn)
      return webNoteWorkspaceJSON([
        "notebookId": .string(saved.notebookId),
        "noteIds": .array(saved.noteIds.map(JSONValue.string))
      ])
    default:
      return webNoteWorkspaceError(status: 404, code: "not_found", message: "Unknown notes agent route")
    }
  }

  private func webNoteConfigAgentResponse(
    action: String,
    request: RielaHTTPRequest
  ) async throws -> RielaHTTPResponse {
    let client = try webNoteWorkspaceClient()
    switch action {
    case "proposals":
      let body: RielaAppWebNoteConfigProposalRequest = try webNoteBody(request)
      if let conflict = webNoteWorkspaceProfileConflict(body.expectedProfile) { return conflict }
      let proposal = try await client.proposeNoteConfigAgentChange(message: body.message)
      return try webNoteWorkspaceJSON([
        "proposal": webNoteEncoded(RielaAppWebNoteConfigProposalPayload(proposal: proposal))
      ])
    case "applications":
      let body: RielaAppWebNoteConfigApplyRequest = try webNoteBody(request)
      if let conflict = webNoteWorkspaceProfileConflict(body.expectedProfile) { return conflict }
      let result = try await client.applyNoteConfigAgentProposal(
        body.proposal.proposal,
        workflowRoot: client.defaultConfigWorkflowRoot
      )
      return try webNoteWorkspaceJSON([
        "tagClass": webNoteEncoded(GraphQLNoteTagClassDTO(tagClass: result.tagClass)),
        "tag": webNoteEncoded(GraphQLNoteTagDTO(tag: result.tag)),
        "autoAction": webNoteEncoded(GraphQLNoteAutoActionDTO(action: result.autoAction)),
        "workflowScaffold": webNoteEncoded(GraphQLNoteWorkflowScaffoldDTO(result: result.workflowScaffold))
      ])
    default:
      return webNoteWorkspaceError(status: 404, code: "not_found", message: "Unknown config-agent route")
    }
  }

  private func webNoteExpansionResponse(
    notebookId: String,
    action: String,
    request: RielaHTTPRequest
  ) async throws -> RielaHTTPResponse {
    let client = try webNoteWorkspaceClient()
    switch action {
    case "prepare":
      let body: RielaAppWebNoteProfileBody = try webNoteBody(request)
      if let conflict = webNoteWorkspaceProfileConflict(body.expectedProfile) { return conflict }
      let notebook = try await client.notebookForExpansion(notebookId: notebookId)
      let session = try await rielaAppBuildNotebookExpansion(notebook: notebook, client: client)
      return webNoteWorkspaceJSON([
        "sourceNotebookId": .string(session.sourceNotebookId),
        "conversationNotebookId": .string(session.conversationNotebookId),
        "initialNoteId": .string(session.initialNoteId),
        "compactSummaryMarkdown": .string(session.compactSummaryMarkdown),
        "sourceNoteIds": .array(session.sourceNoteIds.map(JSONValue.string))
      ])
    case "answers":
      let body: RielaAppWebNoteExpansionAnswerRequest = try webNoteBody(request)
      if let conflict = webNoteWorkspaceProfileConflict(body.expectedProfile) { return conflict }
      let answer = try await client.answerNotebookExpansion(request: RielaNoteNotebookExpansionRequest(
        compactSummaryMarkdown: body.compactSummaryMarkdown,
        questionMarkdown: body.questionMarkdown
      ))
      return try webNoteWorkspaceJSON(["answer": webNoteEncoded(answer)])
    case "turns":
      let body: RielaAppWebNoteExpansionAppendRequest = try webNoteBody(request)
      if let conflict = webNoteWorkspaceProfileConflict(body.expectedProfile) { return conflict }
      let note = try await client.appendNotebookExpansionTurn(
        notebookId: notebookId,
        turnId: body.turnId,
        questionMarkdown: body.questionMarkdown,
        assistantMarkdown: body.assistantMarkdown,
        sourceNoteIds: body.sourceNoteIds
      )
      return try webNoteWorkspaceJSON(["note": webNoteEncoded(GraphQLNoteDTO(note: note))])
    default:
      return webNoteWorkspaceError(status: 404, code: "not_found", message: "Unknown expansion route")
    }
  }

  private func webNoteFileResponse(fileId: String) async throws -> RielaHTTPResponse {
    let resolved = try await webNoteWorkspaceClient().resolveFile(fileId: fileId)
    var headers = ["Content-Type": resolved.file.mediaType]
    if let filename = resolved.file.originalFilename {
      let sanitized = filename.replacingOccurrences(of: "\"", with: "")
      headers["Content-Disposition"] = "inline; filename=\"\(sanitized)\""
    }
    headers["Cache-Control"] = "private, max-age=3600"
    return RielaHTTPResponse(status: 200, headers: headers, body: resolved.data)
  }

  func webNoteWorkspaceClient() throws -> NoteServiceRielaNoteUIClient {
    let environment = ProcessInfo.processInfo.environment
    let settings = RielaAppNoteSettingsStore(noteRoot: noteRootURL(profileName: daemonProfileName)).load()
    let s3Profiles = (try? RielaAppNoteS3ProfileResolver().profiles(
      settings: settings,
      environment: environment
    )) ?? []
    return NoteServiceRielaNoteUIClient(
      service: try webNoteService(),
      s3Profiles: s3Profiles,
      linkProposalProvider: RielaWorkflowNoteLinkProposalProvider.defaultProvider(environment: environment),
      editRewriteProvider: RielaWorkflowNoteEditRewriteProvider.defaultProvider(
        environment: environment,
        allowEnvironmentOverrides: true
      ),
      selectionQuestionProvider: RielaWorkflowNoteSelectionQuestionProvider.defaultProvider(
        environment: environment,
        allowEnvironmentOverrides: true
      ),
      notebookExpansionProvider: RielaNoteWorkflowNotebookCompactProvider.defaultProvider(
        environment: environment,
        allowEnvironmentOverrides: true
      )
    )
  }

  private func webNoteDetailJSON(_ detail: RielaNoteDetail) throws -> RielaHTTPResponse {
    webNoteWorkspaceJSON(["detail": try webNoteDetailValue(detail)])
  }

  private func webNoteDetailValue(_ detail: RielaNoteDetail) throws -> JSONValue {
    .object([
      "note": try webNoteEncoded(GraphQLNoteDTO(note: detail.note)),
      "comments": .array(try detail.comments.map { try webNoteEncoded(GraphQLNoteCommentDTO(comment: $0)) }),
      "links": .array(try detail.links.map { try webNoteEncoded(GraphQLNoteLinkDTO(link: $0)) }),
      "linkedNotes": .object(try detail.linkedNotesById.mapValues { try webNoteEncoded(GraphQLNoteDTO(note: $0)) }),
      "files": .array(try detail.files.map { try webNoteEncoded(GraphQLNoteFileAttachmentDTO(attachment: $0)) })
    ])
  }

  private func webNoteBody<Value: Decodable>(_ request: RielaHTTPRequest) throws -> Value {
    guard let value = try? JSONDecoder().decode(Value.self, from: request.body) else {
      throw RielaAppWebNoteDecodeError(message: "A valid JSON body is required for this route")
    }
    return value
  }

  private func webNoteQueryInt(_ query: String?, name: String) -> Int? {
    guard let query else { return nil }
    for pair in query.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1)
      guard parts.count == 2, parts[0] == Substring(name) else { continue }
      return Int(parts[1])
    }
    return nil
  }

  private func webNoteWorkspaceProfileConflict(_ expectedProfile: String?) -> RielaHTTPResponse? {
    guard expectedProfile == daemonProfileName.rawValue else {
      return webNoteWorkspaceError(
        status: 409,
        code: "profile_conflict",
        message: "The active profile changed after this view was loaded"
      )
    }
    return nil
  }

  private func webNoteWorkspaceJSON(_ object: JSONObject, status: Int = 200) -> RielaHTTPResponse {
    var payload = object
    payload["profile"] = .string(daemonProfileName.rawValue)
    payload["revision"] = .number(Double(webRevision))
    return .json(status: status, .object(payload))
  }

  private func webNoteWorkspaceError(status: Int, code: String, message: String) -> RielaHTTPResponse {
    .json(status: status, .object([
      "error": .object([
        "code": .string(code),
        "message": .string(message)
      ]),
      "revision": .number(Double(webRevision))
    ]))
  }

  private func webNoteWorkspaceFailure(_ error: Error) -> RielaHTTPResponse {
    switch error {
    case RielaNoteEditRewriteError.notConfigured,
         RielaNoteSelectionQuestionError.notConfigured,
         RielaNoteNotebookExpansionError.notConfigured:
      return webNoteWorkspaceError(
        status: 409,
        code: "provider_not_configured",
        message: "This assistant feature requires its riela workflow provider to be configured on the host."
      )
    case RielaNoteEditRewriteError.timedOut,
         RielaNoteSelectionQuestionError.timedOut,
         RielaNoteNotebookExpansionError.timedOut:
      return webNoteWorkspaceError(status: 504, code: "provider_timeout", message: "The assistant workflow timed out.")
    case RielaNoteNotebookExpansionError.sourceChanged:
      return webNoteWorkspaceError(
        status: 409,
        code: "source_changed",
        message: "The notebook changed while it was being summarized. Try again."
      )
    default:
      return webNoteWorkspaceError(status: 400, code: "note_operation_failed", message: error.localizedDescription)
    }
  }
}

struct RielaAppWebNoteDecodeError: Error {
  var message: String
}

private func webNoteEncoded<T: Encodable>(_ value: T) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

// Server-side mirror of the native notebook-expansion orchestration: reuse a
// fresh compact cache when the source marker still matches, otherwise compact
// via the workflow provider, persist the cache, and save the expansion
// conversation notebook.
func rielaAppBuildNotebookExpansion(
  notebook: Notebook,
  client: NoteServiceRielaNoteUIClient
) async throws -> RielaNoteNotebookExpansionSession {
  guard client.isNotebookExpansionConfigured else {
    throw RielaNoteNotebookExpansionError.notConfigured
  }
  let currentMarker = rielaAppNotebookExpansionMarker(for: notebook)
  if let cache = rielaAppNotebookCompactCache(from: notebook.metaJSON),
     rielaAppNotebookCompactCacheIsValid(cache, marker: currentMarker) {
    return try await rielaAppSaveNotebookExpansion(sourceNotebook: notebook, marker: currentMarker, cache: cache, client: client)
  }
  for attempt in 0...1 {
    let sourceNotebook = try await client.notebookForExpansion(notebookId: notebook.notebookId)
    let sourceMarker = rielaAppNotebookExpansionMarker(for: sourceNotebook)
    let notes = try await client.notesForNotebookExpansion(notebookId: notebook.notebookId)
      .sorted { lhs, rhs in
        lhs.noteNumber == rhs.noteNumber ? lhs.noteId < rhs.noteId : lhs.noteNumber < rhs.noteNumber
      }
    guard notes.count == sourceMarker.noteCount else {
      if attempt == 0 { continue }
      throw RielaNoteNotebookExpansionError.sourceChanged
    }
    let draft = try await client.compactNotebook(request: RielaNoteNotebookCompactRequest(
      notebookId: sourceNotebook.notebookId,
      notebookTitle: sourceNotebook.title,
      sourceNotes: notes.map { note in
        RielaNoteNotebookCompactSourceNote(
          noteId: note.noteId,
          noteNumber: note.noteNumber,
          bodyMarkdown: note.bodyMarkdown
        )
      }
    ))
    let summary = draft.summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
    guard draft.version == RielaNoteNotebookCompactCache.supportedVersion, !summary.isEmpty else {
      throw RielaNoteNotebookExpansionError.invalidOutput
    }
    let verifiedNotebook = try await client.notebookForExpansion(notebookId: notebook.notebookId)
    guard rielaAppNotebookExpansionMarker(for: verifiedNotebook) == sourceMarker else {
      if attempt == 0 { continue }
      throw RielaNoteNotebookExpansionError.sourceChanged
    }
    let cache = RielaNoteNotebookCompactCache(
      version: draft.version,
      summaryMarkdown: summary,
      computedAt: rielaAppNotebookExpansionTimestamp(),
      sourceNoteIds: notes.map(\.noteId),
      source: sourceMarker
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let cacheJSON = String(data: try encoder.encode(cache), encoding: .utf8) else {
      throw RielaNoteNotebookExpansionError.invalidOutput
    }
    guard try await client.updateNotebookCompactCache(
      notebookId: notebook.notebookId,
      compactMetadataJSON: cacheJSON,
      expectedMarker: sourceMarker
    ) != nil else {
      if attempt == 0 { continue }
      throw RielaNoteNotebookExpansionError.sourceChanged
    }
    return try await rielaAppSaveNotebookExpansion(sourceNotebook: sourceNotebook, marker: sourceMarker, cache: cache, client: client)
  }
  throw RielaNoteNotebookExpansionError.sourceChanged
}

private func rielaAppSaveNotebookExpansion(
  sourceNotebook: Notebook,
  marker: RielaNoteNotebookExpansionSourceMarker,
  cache: RielaNoteNotebookCompactCache,
  client: NoteServiceRielaNoteUIClient
) async throws -> RielaNoteNotebookExpansionSession {
  let metadata = RielaNoteNotebookExpansionMetadata(
    version: RielaNoteNotebookCompactCache.supportedVersion,
    sourceNotebookId: sourceNotebook.notebookId,
    sourceNoteIds: cache.sourceNoteIds,
    source: marker,
    compactSummaryMarkdown: cache.summaryMarkdown
  )
  let metadataData = try JSONEncoder().encode(metadata)
  let metadataObject = try JSONSerialization.jsonObject(with: metadataData)
  let root = ["rielaNote": ["notebookExpansion": metadataObject]]
  let rootData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  guard let metadataJSON = String(data: rootData, encoding: .utf8) else {
    throw RielaNoteNotebookExpansionError.invalidOutput
  }
  let saved = try await client.saveNotebookExpansion(
    title: "\(sourceNotebook.title) - Agent Expansion",
    seedPromptMarkdown: "Expand this notebook into useful key points and follow-up directions.",
    compactSummaryMarkdown: cache.summaryMarkdown,
    notebookMetaJSON: metadataJSON,
    sourceNoteIds: cache.sourceNoteIds
  )
  guard let initialNoteId = saved.notes.first?.noteId else {
    throw RielaNoteNotebookExpansionError.invalidOutput
  }
  return RielaNoteNotebookExpansionSession(
    sourceNotebookId: sourceNotebook.notebookId,
    conversationNotebookId: saved.notebook.notebookId,
    initialNoteId: initialNoteId,
    compactSummaryMarkdown: cache.summaryMarkdown,
    sourceNoteIds: cache.sourceNoteIds,
    sourceMarker: marker
  )
}

private func rielaAppNotebookExpansionMarker(for notebook: Notebook) -> RielaNoteNotebookExpansionSourceMarker {
  RielaNoteNotebookExpansionSourceMarker(
    updatedAt: notebook.updatedAt,
    noteCount: notebook.noteCount ?? 0
  )
}

private func rielaAppNotebookCompactCache(from metaJSON: String?) -> RielaNoteNotebookCompactCache? {
  guard let metaJSON,
        let data = metaJSON.data(using: .utf8),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let rielaNote = root["rielaNote"] as? [String: Any],
        let compact = rielaNote["notebookCompact"],
        JSONSerialization.isValidJSONObject(compact),
        let compactData = try? JSONSerialization.data(withJSONObject: compact) else {
    return nil
  }
  return try? JSONDecoder().decode(RielaNoteNotebookCompactCache.self, from: compactData)
}

private func rielaAppNotebookCompactCacheIsValid(
  _ cache: RielaNoteNotebookCompactCache,
  marker: RielaNoteNotebookExpansionSourceMarker
) -> Bool {
  cache.version == RielaNoteNotebookCompactCache.supportedVersion
    && !cache.summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    && cache.source == marker
    && cache.sourceNoteIds.count == marker.noteCount
}

private func rielaAppNotebookExpansionTimestamp() -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: Date())
}
#endif
