import Foundation
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

  private let client: any RielaNoteUIClient
  private let searchLimit: Int

  public init(client: any RielaNoteUIClient, searchLimit: Int = 5) {
    self.client = client
    self.searchLimit = searchLimit
  }

  public var canSubmit: Bool {
    !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state != .loading
  }

  public var canSaveTemporaryConversation: Bool {
    isTemporaryChat && hasUnsavedTurns && state != .loading
  }

  public var canStartNewConversation: Bool {
    !turns.isEmpty || !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || autoSaveNotebookId != nil
  }

  public var errorMessage: String? {
    if case let .failed(message) = state {
      return message
    }
    return nil
  }

  public func submitDraft() async {
    let message = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else {
      return
    }
    draftMessage = ""
    state = .loading
    do {
      var turn = try await client.answerNoteAgentTurn(message: message, limit: searchLimit)
      if !isTemporaryChat {
        let result = try await saveOrAppend(turn: turn)
        turn.persistedNoteIds = result.noteIds
      }
      turns.append(turn)
      state = .loaded
    } catch {
      if draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        draftMessage = message
      }
      state = .failed(String(describing: error))
    }
  }

  public func saveTemporaryConversation(title: String? = nil) async {
    let unsavedIndices = unsavedTurnIndices
    guard !unsavedIndices.isEmpty else {
      return
    }
    state = .loading
    do {
      if let autoSaveNotebookId {
        try await appendUnsavedTurns(unsavedIndices, notebookId: autoSaveNotebookId)
      } else {
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
      isTemporaryChat = false
      state = .loaded
    } catch {
      state = .failed(String(describing: error))
    }
  }

  public func startNewConversation() {
    turns = []
    autoSaveNotebookId = nil
    draftMessage = ""
    isTemporaryChat = false
    state = .idle
  }

  private func saveOrAppend(turn: RielaNoteAgentTurn) async throws -> RielaNoteAgentConversationSaveResult {
    if let autoSaveNotebookId {
      return try await client.appendNoteAgentTurn(notebookId: autoSaveNotebookId, turn: turn)
    }
    let result = try await client.saveNoteAgentConversation(title: conversationTitle(firstTurn: turn), turns: [turn])
    autoSaveNotebookId = result.notebookId
    return result
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

  private func conversationTitle(firstTurn: RielaNoteAgentTurn? = nil) -> String {
    let seed = firstTurn?.userMarkdown ?? turns.first?.userMarkdown ?? "Agent conversation"
    let firstLine = seed.split(separator: "\n").first.map(String.init) ?? seed
    return firstLine.isEmpty ? "Agent conversation" : String(firstLine.prefix(80))
  }
}

private enum RielaNoteAgentViewModelError: Error, Equatable, Sendable {
  case unexpectedPersistedNoteCount(expected: Int, actual: Int)
}
