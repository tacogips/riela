import Foundation
import RielaNote

public struct RielaNoteNotebookCompactSourceNote: Codable, Equatable, Sendable {
  public var noteId: String
  public var noteNumber: Int
  public var bodyMarkdown: String

  public init(noteId: String, noteNumber: Int, bodyMarkdown: String) {
    self.noteId = noteId
    self.noteNumber = noteNumber
    self.bodyMarkdown = bodyMarkdown
  }
}

public struct RielaNoteNotebookCompactRequest: Codable, Equatable, Sendable {
  public var notebookId: String
  public var notebookTitle: String
  public var sourceNotes: [RielaNoteNotebookCompactSourceNote]

  public init(
    notebookId: String,
    notebookTitle: String,
    sourceNotes: [RielaNoteNotebookCompactSourceNote]
  ) {
    self.notebookId = notebookId
    self.notebookTitle = notebookTitle
    self.sourceNotes = sourceNotes
  }
}

public struct RielaNoteNotebookCompactDraft: Codable, Equatable, Sendable {
  public var summaryMarkdown: String
  public var version: Int

  public init(summaryMarkdown: String, version: Int) {
    self.summaryMarkdown = summaryMarkdown
    self.version = version
  }
}

public struct RielaNoteNotebookExpansionRequest: Codable, Equatable, Sendable {
  public var compactSummaryMarkdown: String
  public var questionMarkdown: String

  public init(compactSummaryMarkdown: String, questionMarkdown: String) {
    self.compactSummaryMarkdown = compactSummaryMarkdown
    self.questionMarkdown = questionMarkdown
  }
}

public struct RielaNoteNotebookExpansionAnswer: Codable, Equatable, Sendable {
  public var assistantMarkdown: String

  public init(assistantMarkdown: String) {
    self.assistantMarkdown = assistantMarkdown
  }
}

public protocol RielaNoteNotebookExpansionProviding: Sendable {
  func compactNotebook(
    noteRoot: String,
    request: RielaNoteNotebookCompactRequest
  ) async throws -> RielaNoteNotebookCompactDraft

  func answerNotebookExpansion(
    noteRoot: String,
    request: RielaNoteNotebookExpansionRequest
  ) async throws -> RielaNoteNotebookExpansionAnswer
}

public enum RielaNoteNotebookExpansionError: Error, Equatable, Sendable {
  case notConfigured
  case workflowFailed(String)
  case invalidOutput
  case timedOut
  case sourceChanged
}

public struct RielaNoteNotebookExpansionSourceMarker: Codable, Equatable, Sendable {
  public var updatedAt: String
  public var noteCount: Int

  public init(updatedAt: String, noteCount: Int) {
    self.updatedAt = updatedAt
    self.noteCount = noteCount
  }
}

public struct RielaNoteNotebookExpansionSession: Equatable, Sendable {
  public var sourceNotebookId: String
  public var conversationNotebookId: String
  public var initialNoteId: String
  public var compactSummaryMarkdown: String
  public var sourceNoteIds: [String]
  public var sourceMarker: RielaNoteNotebookExpansionSourceMarker

  public init(
    sourceNotebookId: String,
    conversationNotebookId: String,
    initialNoteId: String,
    compactSummaryMarkdown: String,
    sourceNoteIds: [String],
    sourceMarker: RielaNoteNotebookExpansionSourceMarker
  ) {
    self.sourceNotebookId = sourceNotebookId
    self.conversationNotebookId = conversationNotebookId
    self.initialNoteId = initialNoteId
    self.compactSummaryMarkdown = compactSummaryMarkdown
    self.sourceNoteIds = sourceNoteIds
    self.sourceMarker = sourceMarker
  }
}

struct RielaNoteNotebookCompactCache: Codable, Equatable, Sendable {
  static let supportedVersion = 1

  var version: Int
  var summaryMarkdown: String
  var computedAt: String
  var sourceNoteIds: [String]
  var source: RielaNoteNotebookExpansionSourceMarker
}

struct RielaNoteNotebookExpansionMetadata: Codable, Equatable, Sendable {
  var version: Int
  var sourceNotebookId: String
  var sourceNoteIds: [String]
  var source: RielaNoteNotebookExpansionSourceMarker
  var compactSummaryMarkdown: String
}
