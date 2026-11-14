import Foundation

public struct RielaNoteAgentCitation: Codable, Equatable, Identifiable, Sendable {
  public var id: String { noteId }
  public var noteId: String
  public var title: String?
  public var snippet: String?

  public init(noteId: String, title: String? = nil, snippet: String? = nil) {
    self.noteId = noteId
    self.title = title
    self.snippet = snippet
  }
}

public struct RielaNoteAgentTurn: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var userMarkdown: String
  public var assistantMarkdown: String
  public var citations: [RielaNoteAgentCitation]
  public var persistedNoteIds: [String]

  public init(
    id: String = UUID().uuidString,
    userMarkdown: String,
    assistantMarkdown: String,
    citations: [RielaNoteAgentCitation] = [],
    persistedNoteIds: [String] = []
  ) {
    self.id = id
    self.userMarkdown = userMarkdown
    self.assistantMarkdown = assistantMarkdown
    self.citations = citations
    self.persistedNoteIds = persistedNoteIds
  }
}

/// A file the user attached to the agent composer before sending. Attachment
/// text is inlined into the submitted message so any note-agent backend can see
/// it without a dedicated file-upload channel.
public struct RielaNoteAgentDraftAttachment: Equatable, Identifiable, Sendable {
  public var id: String
  public var filename: String
  public var text: String

  public init(id: String = UUID().uuidString, filename: String, text: String) {
    self.id = id
    self.filename = filename
    self.text = text
  }
}

public struct RielaNoteAgentConversationSaveResult: Equatable, Sendable {
  public var notebookId: String
  public var noteIds: [String]

  public init(notebookId: String, noteIds: [String]) {
    self.notebookId = notebookId
    self.noteIds = noteIds
  }
}
