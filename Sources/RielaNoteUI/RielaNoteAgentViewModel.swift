import Foundation
import RielaNote
import SwiftUI

@MainActor
public final class RielaNoteAgentViewModel: ObservableObject {
  public enum LoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
  }

  @Published public private(set) var turns: [RielaNoteAgentTurn] = []
  @Published public private(set) var autoSaveNotebookId: String?
  @Published public private(set) var state: LoadState = .idle
  @Published public var draftMessage = ""
  @Published public var isTemporaryChat = false
  @Published public private(set) var draftAttachments: [RielaNoteAgentDraftAttachment] = []
  @Published public private(set) var attachmentError: String?
  @Published public private(set) var composerFocusRequestRevision = 0
  @Published public private(set) var mode: RielaNoteAgentMode = .general

  /// Inlined attachment text is capped so a huge file cannot blow up the agent
  /// prompt; larger files should be attached to a note instead.
  public static let maximumAttachmentBytes = 256 * 1024

  private let client: any RielaNoteUIClient
  private let searchLimit: Int
  private var isSubmitting = false

  public init(client: any RielaNoteUIClient, searchLimit: Int = 5) {
    self.client = client
    self.searchLimit = searchLimit
  }

  public var canSubmit: Bool {
    let hasDraft = !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasContent = mode.isNotebookExpansion ? hasDraft : hasDraft || !draftAttachments.isEmpty
    return hasContent && state != .loading
  }

  public func addAttachment(filename: String, data: Data) {
    guard !mode.isNotebookExpansion else {
      attachmentError = "Notebook expansion questions use the compact summary only."
      return
    }
    guard data.count <= Self.maximumAttachmentBytes else {
      attachmentError = "\(filename) is too large to attach (max \(Self.maximumAttachmentBytes / 1024) KB)."
      return
    }
    guard let text = String(data: data, encoding: .utf8) else {
      attachmentError = "\(filename) is not a text file. Only text files can be attached here."
      return
    }
    attachmentError = nil
    draftAttachments.append(RielaNoteAgentDraftAttachment(filename: filename, text: text))
  }

  public func removeAttachment(id: String) {
    draftAttachments.removeAll { $0.id == id }
    attachmentError = nil
  }

  public func clearAttachmentError() {
    attachmentError = nil
  }

  public func prepareCurrentNoteQuestion(for note: Note) {
    mode = .general
    let title = note.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayTitle = title?.isEmpty == false ? title ?? note.noteId : note.noteId
    draftMessage = "Ask about \(displayTitle):"
    draftAttachments = [
      RielaNoteAgentDraftAttachment(filename: "\(note.noteId).md", text: note.bodyMarkdown)
    ]
    attachmentError = nil
    composerFocusRequestRevision &+= 1
  }

  public func reportAttachmentReadFailure(filename: String) {
    attachmentError = "Could not read \(filename)."
  }

  /// The message actually sent to the agent: the typed draft followed by each
  /// attachment inlined as a fenced block labelled with its filename.
  func composedDraftMessage() -> String {
    rielaNoteAgentComposedMessage(draft: draftMessage, attachments: draftAttachments)
  }

  public var canSaveTemporaryConversation: Bool {
    !mode.isNotebookExpansion && isTemporaryChat && hasUnsavedTurns && state != .loading
  }

  public var canStartNewConversation: Bool {
    !turns.isEmpty
      || !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !draftAttachments.isEmpty
      || autoSaveNotebookId != nil
      || mode.isNotebookExpansion
  }

  public var errorMessage: String? {
    if case let .failed(message) = state {
      return message
    }
    return nil
  }

  public func submitDraft() async {
    guard !isSubmitting else {
      return
    }
    let message = mode.isNotebookExpansion
      ? draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
      : composedDraftMessage()
    guard !message.isEmpty else {
      return
    }
    isSubmitting = true
    defer { isSubmitting = false }
    draftMessage = ""
    draftAttachments = []
    attachmentError = nil
    state = .loading
    do {
      if case let .notebookExpansion(session) = mode {
        try await submitNotebookExpansionQuestion(message, session: session)
        state = .loaded
        return
      }
      let turn = try await client.answerNoteAgentTurn(message: message, limit: searchLimit)
      // Show first: the answered turn is visible immediately so a persistence
      // failure never discards a paid-for answer.
      turns.append(turn)
      if !isTemporaryChat {
        try await persistUnsavedTurns()
      }
      state = .loaded
    } catch {
      // The answer, if any, is already in `turns` and marked unsaved via its
      // empty `persistedNoteIds`; leave the draft cleared and surface the error.
      rielaNoteLogUIError("noteAgent.submitDraft", error)
      state = .failed("Couldn't complete the agent turn. Please try again.")
    }
  }

  public func saveTemporaryConversation(title: String? = nil) async {
    guard hasUnsavedTurns else {
      return
    }
    state = .loading
    do {
      try await persistUnsavedTurns(title: title)
      isTemporaryChat = false
      state = .loaded
    } catch {
      rielaNoteLogUIError("noteAgent.saveTemporaryConversation", error)
      state = .failed("Couldn't save the conversation. Please try again.")
    }
  }

  public func startNewConversation() {
    turns = []
    autoSaveNotebookId = nil
    draftMessage = ""
    draftAttachments = []
    attachmentError = nil
    isTemporaryChat = false
    mode = .general
    state = .idle
  }

  public func beginNotebookExpansionSession(_ session: RielaNoteNotebookExpansionSession) {
    mode = .notebookExpansion(session)
    turns = [RielaNoteAgentTurn(
      userMarkdown: "Expand this notebook into useful key points and follow-up directions.",
      assistantMarkdown: session.compactSummaryMarkdown,
      persistedNoteIds: [session.initialNoteId]
    )]
    autoSaveNotebookId = session.conversationNotebookId
    draftMessage = ""
    draftAttachments = []
    attachmentError = nil
    isTemporaryChat = false
    state = .loaded
    composerFocusRequestRevision &+= 1
  }

  private func submitNotebookExpansionQuestion(
    _ question: String,
    session: RielaNoteNotebookExpansionSession
  ) async throws {
    let answer = try await client.answerNotebookExpansion(request: RielaNoteNotebookExpansionRequest(
      compactSummaryMarkdown: session.compactSummaryMarkdown,
      questionMarkdown: question
    ))
    // Show first, then persist — mirroring the general agent path — so that a
    // persistence failure (e.g. a source note deleted after this expansion
    // session started, which makes the frozen sourceNoteIds fail validation)
    // never silently discards the paid-for answer or wedges the conversation.
    let turnIndex = turns.count
    turns.append(RielaNoteAgentTurn(
      userMarkdown: question,
      assistantMarkdown: answer.assistantMarkdown,
      persistedNoteIds: []
    ))
    let note = try await client.appendNotebookExpansionTurn(
      notebookId: session.conversationNotebookId,
      questionMarkdown: question,
      assistantMarkdown: answer.assistantMarkdown,
      sourceNoteIds: session.sourceNoteIds
    )
    turns[turnIndex].persistedNoteIds = [note.noteId]
  }

  private func persistUnsavedTurns(title: String? = nil) async throws {
    let unsavedIndices = unsavedTurnIndices
    guard !unsavedIndices.isEmpty else {
      return
    }
    if let autoSaveNotebookId {
      try await appendUnsavedTurns(unsavedIndices, notebookId: autoSaveNotebookId)
      return
    }
    // First non-temp save persists ALL unsaved turns, not just the newest, so
    // leaving temp mode never strands earlier turns.
    let unsavedTurns = unsavedIndices.map { turns[$0] }
    let result = try await client.saveNoteAgentConversation(
      title: title ?? conversationTitle(),
      turns: unsavedTurns
    )
    guard result.noteIds.count == unsavedIndices.count else {
      throw RielaNoteAgentViewModelError.unexpectedPersistedNoteCount(
        expected: unsavedIndices.count,
        actual: result.noteIds.count
      )
    }
    autoSaveNotebookId = result.notebookId
    assignPersistedNoteIds(result.noteIds, to: unsavedIndices)
  }

  private var hasUnsavedTurns: Bool {
    turns.contains { $0.persistedNoteIds.isEmpty }
  }

  private var unsavedTurnIndices: [Int] {
    turns.indices.filter { turns[$0].persistedNoteIds.isEmpty }
  }

  private func appendUnsavedTurns(_ indices: [Int], notebookId: String) async throws {
    for index in indices {
      let result = try await client.appendNoteAgentTurn(notebookId: notebookId, turn: turns[index])
      guard result.noteIds.count == 1 else {
        throw RielaNoteAgentViewModelError.unexpectedPersistedNoteCount(expected: 1, actual: result.noteIds.count)
      }
      turns[index].persistedNoteIds = result.noteIds
    }
  }

  private func assignPersistedNoteIds(_ noteIds: [String], to indices: [Int]) {
    guard noteIds.count == indices.count else {
      return
    }
    for (offset, index) in indices.enumerated() {
      turns[index].persistedNoteIds = [noteIds[offset]]
    }
  }

  private func conversationTitle() -> String {
    let seed = turns.first?.userMarkdown ?? "Agent conversation"
    let firstLine = seed.split(separator: "\n").first.map(String.init) ?? seed
    return firstLine.isEmpty ? "Agent conversation" : String(firstLine.prefix(80))
  }
}

private extension RielaNoteAgentMode {
  var isNotebookExpansion: Bool {
    if case .notebookExpansion = self {
      return true
    }
    return false
  }
}

private enum RielaNoteAgentViewModelError: Error, Equatable, Sendable {
  case unexpectedPersistedNoteCount(expected: Int, actual: Int)
}

/// Builds the outgoing agent message from the typed draft plus inlined
/// attachments. A fence longer than any backtick run inside the content keeps
/// the blocks well-formed even when a file itself contains fenced code.
func rielaNoteAgentComposedMessage(
  draft: String,
  attachments: [RielaNoteAgentDraftAttachment]
) -> String {
  let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !attachments.isEmpty else {
    return trimmedDraft
  }
  let attachmentSections = attachments.map { attachment in
    let fence = rielaNoteAgentAttachmentFence(for: attachment.text)
    return "Attached file `\(attachment.filename)`:\n\(fence)\n\(attachment.text)\n\(fence)"
  }
  return ([trimmedDraft] + attachmentSections)
    .filter { !$0.isEmpty }
    .joined(separator: "\n\n")
}

private func rielaNoteAgentAttachmentFence(for text: String) -> String {
  var longestRun = 0
  var currentRun = 0
  for character in text {
    if character == "`" {
      currentRun += 1
      longestRun = max(longestRun, currentRun)
    } else {
      currentRun = 0
    }
  }
  return String(repeating: "`", count: max(3, longestRun + 1))
}
