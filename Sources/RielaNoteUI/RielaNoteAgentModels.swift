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

public struct RielaNoteAgentConversationSaveResult: Equatable, Sendable {
  public var notebookId: String
  public var noteIds: [String]

  public init(notebookId: String, noteIds: [String]) {
    self.notebookId = notebookId
    self.noteIds = noteIds
  }
}
