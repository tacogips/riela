import Foundation
import RielaNote

public struct RielaNoteDetail: Equatable, Sendable {
  public var note: Note
  public var comments: [NoteComment]
  public var links: [NoteLink]
  public var linkedNotesById: [String: Note]
  public var files: [NoteFileAttachment]

  public init(
    note: Note,
    comments: [NoteComment] = [],
    links: [NoteLink] = [],
    linkedNotesById: [String: Note] = [:],
    files: [NoteFileAttachment] = []
  ) {
    self.note = note
    self.comments = comments
    self.links = links
    self.linkedNotesById = linkedNotesById
    self.files = files
  }
}

public struct RielaNoteResolvedFile: Equatable, Sendable {
  public var file: FileRecord
  public var data: Data

  public init(file: FileRecord, data: Data) {
    self.file = file
    self.data = data
  }
}

public struct RielaNoteNotebookNotesWindow: Equatable, Sendable {
  public var notes: [Note]
  public var startOffset: Int
  public var hasEarlierNotes: Bool
  public var hasMoreNotes: Bool

  public init(
    notes: [Note],
    startOffset: Int,
    hasEarlierNotes: Bool,
    hasMoreNotes: Bool
  ) {
    self.notes = notes
    self.startOffset = startOffset
    self.hasEarlierNotes = hasEarlierNotes
    self.hasMoreNotes = hasMoreNotes
  }
}

public enum RielaNoteUIClientCapabilityError: Error, Equatable, Sendable {
  case currentNotebookNoteCreationUnsupported
  case commentPromotionUnsupported
  case notebookNotesWindowUnsupported
}

public struct RielaNoteListFilter: Equatable, Sendable {
  public enum CreatedRange: String, Equatable, Sendable, CaseIterable {
    case any
    case today
    case last7Days
    case last30Days
    case custom
  }

  public var sort: NoteListSort
  public var createdRange: CreatedRange
  public var includeLinked: Bool
  public var customCreatedAfter: String
  public var customCreatedBefore: String

  public init(
    sort: NoteListSort = .createdAtDesc,
    createdRange: CreatedRange = .any,
    includeLinked: Bool = false,
    customCreatedAfter: String = "",
    customCreatedBefore: String = ""
  ) {
    self.sort = sort
    self.createdRange = createdRange
    self.includeLinked = includeLinked
    self.customCreatedAfter = customCreatedAfter
    self.customCreatedBefore = customCreatedBefore
  }
}

public protocol RielaNoteUIClient: Sendable {
  var defaultConfigWorkflowRoot: String { get }
  var noteStoreChangeObservationURLs: [URL] { get }

  func listNotebooks(limit: Int, offset: Int) async throws -> [Notebook]
  func listNotebooks(limit: Int, offset: Int, filter: RielaNoteListFilter) async throws -> [Notebook]
  func listNotes(notebookId: String, limit: Int, offset: Int) async throws -> [Note]
  func notebookNotesWindow(containing noteId: String, pageSize: Int) async throws -> RielaNoteNotebookNotesWindow
  func listTags() async throws -> [Tag]
  func listTagClasses() async throws -> [TagClass]
  func createUserMemo(bodyMarkdown: String) async throws -> RielaNoteDetail
  func createNote(inNotebook notebookId: String, bodyMarkdown: String) async throws -> RielaNoteDetail
  func searchNotes(
    query: String,
    tagFilter: [String],
    classFilter: [String],
    limit: Int,
    offset: Int
  ) async throws -> [NoteSearchResult]
  func searchNotes(
    query: String,
    tagFilter: [String],
    classFilter: [String],
    filter: RielaNoteListFilter,
    limit: Int,
    offset: Int
  ) async throws -> [NoteSearchResult]
  func noteDetail(noteId: String) async throws -> RielaNoteDetail
  func firstNote(inNotebook notebookId: String) async throws -> RielaNoteDetail?
  func resolveFile(fileId: String) async throws -> RielaNoteResolvedFile
  func updateNoteBody(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail
  func applyTag(noteId: String, tagName: String, classId: String?) async throws -> RielaNoteDetail
  func removeTag(noteId: String, tagName: String) async throws -> RielaNoteDetail
  func addComment(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail
  func addComment(noteId: String, bodyMarkdown: String, author: String) async throws -> RielaNoteDetail
  func promoteCommentToNotebook(noteId: String, commentId: String) async throws -> RielaNoteDetail
  func linkNote(noteId: String, targetNoteId: String, linkKind: String) async throws -> RielaNoteDetail
  func linkNote(
    noteId: String,
    targetNoteId: String,
    linkKind: String,
    provenance: NoteProvenance
  ) async throws -> RielaNoteDetail
  func proposeNoteLinks(noteId: String) async throws -> [NoteLinkProposal]
  func proposeNoteBodyRewrite(
    noteId: String,
    instruction: String,
    bodyMarkdown: String,
    selectedText: String?,
    selectionStart: Int?,
    selectionEnd: Int?
  ) async throws -> RielaNoteEditRewriteDraft
  func answerNoteSelectionQuestion(
    noteId: String,
    question: String,
    bodyMarkdown: String,
    selectedText: String,
    selectionStart: Int,
    selectionEnd: Int
  ) async throws -> RielaNoteSelectionAnswerDraft
  func answerNoteAgentTurn(message: String, limit: Int) async throws -> RielaNoteAgentTurn
  func saveNoteAgentConversation(
    title: String,
    turns: [RielaNoteAgentTurn]
  ) async throws -> RielaNoteAgentConversationSaveResult
  func appendNoteAgentTurn(
    notebookId: String,
    turn: RielaNoteAgentTurn
  ) async throws -> RielaNoteAgentConversationSaveResult
  func proposeNoteConfigAgentChange(message: String) async throws -> RielaNoteConfigAgentProposal
  func applyNoteConfigAgentProposal(
    _ proposal: RielaNoteConfigAgentProposal,
    workflowRoot: String
  ) async throws -> RielaNoteConfigAgentApplyResult
}

public extension RielaNoteUIClient {
  var noteStoreChangeObservationURLs: [URL] {
    []
  }

  func listTagClasses() async throws -> [TagClass] {
    []
  }

  func createNote(inNotebook notebookId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw RielaNoteUIClientCapabilityError.currentNotebookNoteCreationUnsupported
  }

  func listNotebooks(limit: Int, offset: Int, filter: RielaNoteListFilter) async throws -> [Notebook] {
    try await listNotebooks(limit: limit, offset: offset)
  }

  func notebookNotesWindow(containing noteId: String, pageSize: Int) async throws -> RielaNoteNotebookNotesWindow {
    let detail = try await noteDetail(noteId: noteId)
    let boundedPageSize = max(pageSize, 1)
    let firstPage = try await listNotes(
      notebookId: detail.note.notebookId,
      limit: boundedPageSize + 1,
      offset: 0
    )
    let visiblePage = Array(firstPage.prefix(boundedPageSize))
    if visiblePage.contains(where: { $0.noteId == noteId }) {
      return RielaNoteNotebookNotesWindow(
        notes: visiblePage,
        startOffset: 0,
        hasEarlierNotes: false,
        hasMoreNotes: firstPage.count > boundedPageSize
      )
    }
    throw RielaNoteUIClientCapabilityError.notebookNotesWindowUnsupported
  }

  func searchNotes(
    query: String,
    tagFilter: [String],
    classFilter: [String],
    filter: RielaNoteListFilter,
    limit: Int,
    offset: Int
  ) async throws -> [NoteSearchResult] {
    try await searchNotes(query: query, tagFilter: tagFilter, classFilter: classFilter, limit: limit, offset: offset)
  }

  func linkNote(
    noteId: String,
    targetNoteId: String,
    linkKind: String,
    provenance: NoteProvenance
  ) async throws -> RielaNoteDetail {
    try await linkNote(noteId: noteId, targetNoteId: targetNoteId, linkKind: linkKind)
  }

  func proposeNoteLinks(noteId: String) async throws -> [NoteLinkProposal] {
    []
  }

  func proposeNoteBodyRewrite(
    noteId: String,
    instruction: String,
    bodyMarkdown: String,
    selectedText: String?,
    selectionStart: Int?,
    selectionEnd: Int?
  ) async throws -> RielaNoteEditRewriteDraft {
    throw RielaNoteEditRewriteError.notConfigured
  }

  func answerNoteSelectionQuestion(
    noteId: String,
    question: String,
    bodyMarkdown: String,
    selectedText: String,
    selectionStart: Int,
    selectionEnd: Int
  ) async throws -> RielaNoteSelectionAnswerDraft {
    throw RielaNoteSelectionQuestionError.notConfigured
  }

  func addComment(noteId: String, bodyMarkdown: String, author: String) async throws -> RielaNoteDetail {
    try await addComment(noteId: noteId, bodyMarkdown: bodyMarkdown)
  }

  func promoteCommentToNotebook(noteId: String, commentId: String) async throws -> RielaNoteDetail {
    throw RielaNoteUIClientCapabilityError.commentPromotionUnsupported
  }
}

public extension RielaNoteListFilter {
  var createdAfter: String? {
    guard createdRange != .any else {
      return nil
    }
    let calendar = Calendar(identifier: .gregorian)
    let now = Date()
    let startDate: Date
    switch createdRange {
    case .any:
      return nil
    case .custom:
      let trimmed = customCreatedAfter.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    case .today:
      startDate = calendar.startOfDay(for: now)
    case .last7Days:
      startDate = calendar.date(byAdding: .day, value: -7, to: now) ?? now
    case .last30Days:
      startDate = calendar.date(byAdding: .day, value: -30, to: now) ?? now
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: startDate)
  }

  var createdBefore: String? {
    guard createdRange == .custom else {
      return nil
    }
    let trimmed = customCreatedBefore.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

func rielaNoteAllowedLinkKind(_ rawValue: String) -> String {
  let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
  switch normalized {
  case "related", "source-citation":
    return normalized
  default:
    return "related"
  }
}

func rielaNoteCreatedBoundInputIsValid(_ rawValue: String) -> Bool {
  let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else {
    return true
  }
  if trimmed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
    return true
  }
  let internetFormatter = ISO8601DateFormatter()
  let fractionalFormatter = ISO8601DateFormatter()
  fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return internetFormatter.date(from: trimmed) != nil || fractionalFormatter.date(from: trimmed) != nil
}

public struct NoteServiceRielaNoteUIClient: RielaNoteUIClient {
  private static let linkProposalLimit = 8
  private let service: NoteService
  private let s3Profiles: [S3StorageProfile]
  private let s3HTTPClient: any S3HTTPClient
  private let linkProposalProvider: (any RielaNoteLinkProposalProviding)?
  private let editRewriteProvider: (any RielaNoteEditRewriteProviding)?
  private let selectionQuestionProvider: (any RielaNoteSelectionQuestionProviding)?

  public init(
    service: NoteService,
    s3Profiles: [S3StorageProfile] = [],
    s3HTTPClient: any S3HTTPClient = URLSessionS3HTTPClient(),
    linkProposalProvider: (any RielaNoteLinkProposalProviding)? = nil,
    editRewriteProvider: (any RielaNoteEditRewriteProviding)? = nil,
    selectionQuestionProvider: (any RielaNoteSelectionQuestionProviding)? = nil
  ) {
    self.service = service
    self.s3Profiles = s3Profiles
    self.s3HTTPClient = s3HTTPClient
    self.linkProposalProvider = linkProposalProvider
    self.editRewriteProvider = editRewriteProvider
    self.selectionQuestionProvider = selectionQuestionProvider
  }

  public func listNotebooks(limit: Int, offset: Int) async throws -> [Notebook] {
    try service.listNotebooks(limit: limit, offset: offset)
  }

  public func listNotebooks(limit: Int, offset: Int, filter: RielaNoteListFilter) async throws -> [Notebook] {
    try service.listNotebooks(
      limit: limit,
      offset: offset,
      sort: filter.sort,
      createdAfter: filter.createdAfter,
      createdBefore: filter.createdBefore
    )
  }

  public func listNotes(notebookId: String, limit: Int, offset: Int) async throws -> [Note] {
    try service.listNotes(notebookId: notebookId, limit: limit, offset: offset)
  }

  public func notebookNotesWindow(
    containing noteId: String,
    pageSize: Int
  ) async throws -> RielaNoteNotebookNotesWindow {
    let note = try service.getNote(noteId)
    let targetOffset = try service.noteOffsetInNotebook(noteId: noteId)
    let boundedPageSize = max(pageSize, 1)
    let startOffset = max(targetOffset - (boundedPageSize / 2), 0)
    let page = try service.listNotes(
      notebookId: note.notebookId,
      limit: boundedPageSize + 1,
      offset: startOffset
    )
    return RielaNoteNotebookNotesWindow(
      notes: Array(page.prefix(boundedPageSize)),
      startOffset: startOffset,
      hasEarlierNotes: startOffset > 0,
      hasMoreNotes: page.count > boundedPageSize
    )
  }

  public func listTags() async throws -> [Tag] {
    try service.listTags()
  }

  public func listTagClasses() async throws -> [TagClass] {
    try service.listTagClasses()
  }

  public func createUserMemo(bodyMarkdown: String) async throws -> RielaNoteDetail {
    let note = try service.createNote(
      notebookTitle: "User Memo",
      notebookKindTagName: "notebook-kind:user-memo",
      bodyMarkdown: bodyMarkdown,
      tags: [NoteTagInput(name: "user-memo", classId: "topic")],
      provenance: .human,
      assignedBy: "riela-note-ui"
    )
    return try detail(noteId: note.noteId)
  }

  public func createNote(inNotebook notebookId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    let note = try service.createNote(
      notebookId: notebookId,
      bodyMarkdown: bodyMarkdown,
      tags: [NoteTagInput(name: "user-memo", classId: "topic")],
      provenance: .human,
      assignedBy: "riela-note-ui"
    )
    return try detail(noteId: note.noteId)
  }

  public var defaultConfigWorkflowRoot: String {
    URL(fileURLWithPath: service.driver.databasePath)
      .deletingLastPathComponent()
      .appendingPathComponent("workflows", isDirectory: true)
      .path
  }

  public var noteStoreChangeObservationURLs: [URL] {
    let databaseURL = URL(fileURLWithPath: service.driver.databasePath)
    return [
      databaseURL,
      URL(fileURLWithPath: "\(service.driver.databasePath)-wal"),
      URL(fileURLWithPath: "\(service.driver.databasePath)-shm")
    ]
  }

  public func searchNotes(
    query: String,
    tagFilter: [String],
    classFilter: [String],
    limit: Int,
    offset: Int
  ) async throws -> [NoteSearchResult] {
    try service.searchNotes(query: query, tagFilter: tagFilter, classFilter: classFilter, limit: limit, offset: offset)
  }

  public func searchNotes(
    query: String,
    tagFilter: [String],
    classFilter: [String],
    filter: RielaNoteListFilter,
    limit: Int,
    offset: Int
  ) async throws -> [NoteSearchResult] {
    try service.searchNotes(
      query: query,
      tagFilter: tagFilter,
      classFilter: classFilter,
      sort: filter.sort,
      createdAfter: filter.createdAfter,
      createdBefore: filter.createdBefore,
      includeLinked: filter.includeLinked,
      limit: limit,
      offset: offset
    )
  }

  public func noteDetail(noteId: String) async throws -> RielaNoteDetail {
    try detail(noteId: noteId)
  }

  public func firstNote(inNotebook notebookId: String) async throws -> RielaNoteDetail? {
    guard let note = try service.listNotes(notebookId: notebookId, limit: 1).first else {
      return nil
    }
    return try detail(noteId: note.noteId)
  }

  public func resolveFile(fileId: String) async throws -> RielaNoteResolvedFile {
    let record = try service.getFileRecord(fileId: fileId)
    let data: Data
    if let asyncS3HTTPClient = s3HTTPClient as? any AsyncS3HTTPClient {
      data = try await service.resolveFileContent(
        fileId: fileId,
        s3Profiles: s3Profiles,
        httpClient: asyncS3HTTPClient
      )
    } else {
      data = try service.resolveFileContent(fileId: fileId, s3Profiles: s3Profiles, httpClient: s3HTTPClient)
    }
    return RielaNoteResolvedFile(file: record, data: data)
  }

  public func updateNoteBody(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    _ = try service.updateNoteBody(noteId: noteId, bodyMarkdown: bodyMarkdown)
    return try detail(noteId: noteId)
  }

  public func applyTag(noteId: String, tagName: String, classId: String?) async throws -> RielaNoteDetail {
    _ = try service.applyTags(
      noteId: noteId,
      tags: [NoteTagInput(name: tagName, classId: classId)],
      provenance: .human,
      assignedBy: "riela-note-ui"
    )
    return try detail(noteId: noteId)
  }

  public func removeTag(noteId: String, tagName: String) async throws -> RielaNoteDetail {
    _ = try service.removeTag(noteId: noteId, tagName: tagName, removedBy: .human)
    return try detail(noteId: noteId)
  }

  public func addComment(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    try await addComment(noteId: noteId, bodyMarkdown: bodyMarkdown, author: "user")
  }

  public func addComment(noteId: String, bodyMarkdown: String, author: String) async throws -> RielaNoteDetail {
    _ = try service.addComment(noteId: noteId, bodyMarkdown: bodyMarkdown, author: author)
    return try detail(noteId: noteId)
  }

  public func promoteCommentToNotebook(noteId: String, commentId: String) async throws -> RielaNoteDetail {
    _ = try service.promoteCommentToNotebook(noteId: noteId, commentId: commentId)
    return try detail(noteId: noteId)
  }

  public func linkNote(noteId: String, targetNoteId: String, linkKind: String) async throws -> RielaNoteDetail {
    _ = try service.linkNotes(from: noteId, to: targetNoteId, linkKind: linkKind, provenance: .human)
    return try detail(noteId: noteId)
  }

  public func linkNote(
    noteId: String,
    targetNoteId: String,
    linkKind: String,
    provenance: NoteProvenance
  ) async throws -> RielaNoteDetail {
    _ = try service.linkNotes(from: noteId, to: targetNoteId, linkKind: linkKind, provenance: provenance)
    return try detail(noteId: noteId)
  }

  public func proposeNoteLinks(noteId: String) async throws -> [NoteLinkProposal] {
    if let linkProposalProvider {
      return try await workflowNoteLinkProposals(
        noteId: noteId,
        provider: linkProposalProvider,
        limit: Self.linkProposalLimit
      )
    }
    return try service.proposeLinks(noteId: noteId, limit: Self.linkProposalLimit)
  }

  public func proposeNoteBodyRewrite(
    noteId: String,
    instruction: String,
    bodyMarkdown: String,
    selectedText: String?,
    selectionStart: Int?,
    selectionEnd: Int?
  ) async throws -> RielaNoteEditRewriteDraft {
    guard let editRewriteProvider else {
      throw RielaNoteEditRewriteError.notConfigured
    }
    return try await editRewriteProvider.proposeRewrite(
      noteId: noteId,
      noteRoot: service.noteRootPath(),
      instruction: instruction,
      bodyMarkdown: bodyMarkdown,
      selectedText: selectedText,
      selectionStart: selectionStart,
      selectionEnd: selectionEnd
    )
  }

  public func answerNoteSelectionQuestion(
    noteId: String,
    question: String,
    bodyMarkdown: String,
    selectedText: String,
    selectionStart: Int,
    selectionEnd: Int
  ) async throws -> RielaNoteSelectionAnswerDraft {
    guard let selectionQuestionProvider else {
      throw RielaNoteSelectionQuestionError.notConfigured
    }
    return try await selectionQuestionProvider.answerQuestion(
      noteId: noteId,
      noteRoot: service.noteRootPath(),
      question: question,
      bodyMarkdown: bodyMarkdown,
      selectedText: selectedText,
      selectionStart: selectionStart,
      selectionEnd: selectionEnd
    )
  }

  public func answerNoteAgentTurn(message: String, limit: Int) async throws -> RielaNoteAgentTurn {
    let results = try service.searchNotes(query: message, tagFilter: [], classFilter: [], limit: limit)
    let citations = results.map { result in
      RielaNoteAgentCitation(
        noteId: result.note.noteId,
        title: result.note.title,
        snippet: result.snippet
      )
    }
    return RielaNoteAgentTurn(
      userMarkdown: message,
      assistantMarkdown: noteAgentAnswer(message: message, citations: citations),
      citations: citations
    )
  }

  public func saveNoteAgentConversation(
    title: String,
    turns: [RielaNoteAgentTurn]
  ) async throws -> RielaNoteAgentConversationSaveResult {
    let saved = try service.saveConversation(
      title: title,
      transcript: turns.map(noteConversationTurn),
      assignedBy: "riela-note-agent"
    )
    return RielaNoteAgentConversationSaveResult(
      notebookId: saved.notebook.notebookId,
      noteIds: saved.notes.map(\.noteId)
    )
  }

  public func appendNoteAgentTurn(
    notebookId: String,
    turn: RielaNoteAgentTurn
  ) async throws -> RielaNoteAgentConversationSaveResult {
    let note = try service.appendConversationTurn(
      notebookId: notebookId,
      turn: noteConversationTurn(turn),
      assignedBy: "riela-note-agent"
    )
    return RielaNoteAgentConversationSaveResult(notebookId: notebookId, noteIds: [note.noteId])
  }

  public func proposeNoteConfigAgentChange(message: String) async throws -> RielaNoteConfigAgentProposal {
    let slug = noteConfigSlug(from: message)
    let label = noteConfigLabel(from: message)
    let tagClass = RielaNoteConfigTagClassDraft(
      classId: slug,
      label: label,
      description: "Defined by the Riela Note config agent."
    )
    let tag = RielaNoteConfigTagDraft(name: slug, classId: slug)
    let workflowId = "note-ingest-\(slug)"
    return RielaNoteConfigAgentProposal(
      requestMarkdown: message,
      assistantMarkdown: """
      Proposed configuration change:
      - define tag class `\(slug)`
      - bind tag `\(slug)` to that class
      - route matching note-created events through `note-auto-tagging`
      - scaffold ingestion workflow `\(workflowId)`
      """,
      tagClass: tagClass,
      tag: tag,
      autoAction: RielaNoteConfigAutoActionDraft(
        actionId: "config-agent-auto-tagging-\(slug)",
        trigger: NoteAutoActionTrigger.noteCreated.rawValue,
        workflowId: NoteStoreSchema.autoTaggingWorkflowId,
        filterJSON: #"{"noteTags":["\#(slug)"]}"#,
        enabled: true,
        position: 10
      ),
      ingestionWorkflow: RielaNoteConfigIngestionWorkflowDraft(workflowId: workflowId)
    )
  }

  public func applyNoteConfigAgentProposal(
    _ proposal: RielaNoteConfigAgentProposal,
    workflowRoot: String
  ) async throws -> RielaNoteConfigAgentApplyResult {
    // Validate before mutate: reject an unsafe workflow id up front so the
    // proposal never commits tag/tag-class/auto-action rows the scaffolder
    // would then refuse (leaving the store half-configured).
    let workflowId = proposal.ingestionWorkflow.workflowId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isSafeConfigWorkflowId(workflowId) else {
      throw NoteServiceError.invalidInput(
        "workflow id must contain lowercase letters, numbers, and dashes"
      )
    }
    let tagClass = try service.defineTagClass(
      classId: proposal.tagClass.classId,
      label: proposal.tagClass.label,
      description: proposal.tagClass.description
    )
    let tag = try service.defineTag(name: proposal.tag.name, classId: proposal.tag.classId)
    let trigger = NoteAutoActionTrigger(rawValue: proposal.autoAction.trigger) ?? .noteCreated
    let autoAction = try service.configureAutoAction(
      actionId: proposal.autoAction.actionId,
      trigger: trigger,
      workflowId: proposal.autoAction.workflowId,
      filterJSON: proposal.autoAction.filterJSON,
      enabled: proposal.autoAction.enabled,
      position: proposal.autoAction.position
    )
    let scaffold = try NoteIngestionWorkflowScaffolder().scaffold(
      workflowRoot: workflowRoot,
      workflowId: proposal.ingestionWorkflow.workflowId,
      notebookKindTag: proposal.ingestionWorkflow.notebookKindTag,
      translationEnabled: proposal.ingestionWorkflow.translationEnabled
    )
    return RielaNoteConfigAgentApplyResult(
      tagClass: tagClass,
      tag: tag,
      autoAction: autoAction,
      workflowScaffold: scaffold
    )
  }

  private func detail(noteId: String) throws -> RielaNoteDetail {
    let note = try service.getNote(noteId)
    let links = try service.listLinks(noteId: noteId)
    return try RielaNoteDetail(
      note: note,
      comments: service.listComments(noteId: noteId),
      links: links,
      linkedNotesById: linkedNotesById(for: noteId, links: links),
      files: service.listFiles(noteId: noteId)
    )
  }

  private func linkedNotesById(for noteId: String, links: [NoteLink]) throws -> [String: Note] {
    var linkedNotes: [String: Note] = [:]
    for linkedNoteId in Set(links.map { $0.counterpartNoteId(for: noteId) }) {
      linkedNotes[linkedNoteId] = try service.getNote(linkedNoteId)
    }
    return linkedNotes
  }

  private func workflowNoteLinkProposals(
    noteId: String,
    provider: any RielaNoteLinkProposalProviding,
    limit: Int
  ) async throws -> [NoteLinkProposal] {
    let note = try service.getNote(noteId)
    let drafts = try await provider.proposeLinkDrafts(
      noteId: noteId,
      noteRoot: service.noteRootPath(),
      query: noteLinkProposalQuery(from: note.bodyMarkdown),
      limit: limit
    )
    let links = try service.listLinks(noteId: noteId)
    let excludedNoteIds = Set(links.map { $0.counterpartNoteId(for: noteId) } + [noteId])
    var seenNoteIds = excludedNoteIds
    var proposals: [NoteLinkProposal] = []
    for draft in drafts.prefix(limit) where seenNoteIds.insert(draft.targetNoteId).inserted {
      guard let targetNote = try? service.getNote(draft.targetNoteId) else {
        continue
      }
      proposals.append(NoteLinkProposal(
        targetNote: targetNote,
        linkKind: rielaNoteAllowedLinkKind(draft.linkKind),
        reason: draft.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? "Suggested by note-link-extract."
          : draft.reason,
        source: "workflow"
      ))
    }
    return proposals
  }

  private func noteConversationTurn(_ turn: RielaNoteAgentTurn) -> NoteConversationTurn {
    NoteConversationTurn(
      userMarkdown: turn.userMarkdown,
      assistantMarkdown: turn.assistantMarkdown,
      sourceNoteIds: turn.citations.map(\.noteId)
    )
  }

  private func noteAgentAnswer(message: String, citations: [RielaNoteAgentCitation]) -> String {
    guard !citations.isEmpty else {
      return "No matching Riela Note source was found for: \(message)"
    }
    let sourceList = citations.prefix(3).enumerated().map { index, citation in
      let title = citation.title ?? citation.noteId
      let snippet = citation.snippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !snippet.isEmpty else {
        return "\(index + 1). \(title) [\(citation.noteId)]"
      }
      return "\(index + 1). \(title) [\(citation.noteId)]\n   \(snippet)"
    }.joined(separator: "\n")
    return """
    I found \(citations.count) relevant note source(s) for "\(message)".

    \(sourceList)
    """
  }

  private func noteConfigSlug(from message: String) -> String {
    // Restrict to ASCII [a-z0-9-] so the derived slug always satisfies
    // `isSafeWorkflowId`; non-ASCII input (e.g. Japanese) falls back to the
    // default slug rather than producing a workflow id the scaffolder rejects.
    let scalars = message.lowercased().unicodeScalars.map { scalar -> Character in
      isSafeSlugScalar(scalar) ? Character(scalar) : "-"
    }
    let collapsed = String(scalars).split(separator: "-").prefix(4).joined(separator: "-")
    return collapsed.isEmpty ? Self.defaultConfigSlug : String(collapsed.prefix(48))
  }

  private func isSafeSlugScalar(_ scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
  }

  // Mirrors `NoteIngestionWorkflowScaffolder`'s workflow-id rule so validation
  // fails identically before any DB write rather than after the scaffold step.
  private func isSafeConfigWorkflowId(_ workflowId: String) -> Bool {
    guard workflowId.count >= 2, workflowId.count <= 64 else {
      return false
    }
    return workflowId.unicodeScalars.allSatisfy { scalar in
      isSafeSlugScalar(scalar) || scalar == "-"
    }
  }

  private static let defaultConfigSlug = "config-agent-topic"

  private func noteConfigLabel(from message: String) -> String {
    let firstLine = message.split(separator: "\n").first.map(String.init) ?? message
    let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Config Agent Topic" : String(trimmed.prefix(80))
  }
}

private func noteLinkProposalQuery(from bodyMarkdown: String) -> String {
  var seen = Set<String>()
  var terms: [String] = []
  var current = String.UnicodeScalarView()
  func flushCurrentTerm() {
    let term = String(current).trimmingCharacters(in: .whitespacesAndNewlines)
    current.removeAll(keepingCapacity: true)
    guard term.count >= 4, seen.insert(term.lowercased()).inserted else {
      return
    }
    terms.append(term)
  }
  for scalar in bodyMarkdown.unicodeScalars {
    if CharacterSet.alphanumerics.contains(scalar) {
      current.append(scalar)
    } else {
      flushCurrentTerm()
    }
    if terms.count >= 6 {
      break
    }
  }
  if terms.count < 6 {
    flushCurrentTerm()
  }
  return terms.joined(separator: " ")
}

private extension NoteLink {
  func counterpartNoteId(for noteId: String) -> String {
    fromNoteId == noteId ? toNoteId : fromNoteId
  }
}
