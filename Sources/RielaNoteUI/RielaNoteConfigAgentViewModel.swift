import Foundation
import SwiftUI

@MainActor
public final class RielaNoteConfigAgentViewModel: ObservableObject {
  public enum LoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
  }

  @Published public private(set) var proposals: [RielaNoteConfigAgentProposal] = []
  @Published public private(set) var state: LoadState = .idle
  @Published public var draftMessage = ""
  @Published public var workflowRoot: String

  private let client: any RielaNoteUIClient

  public init(client: any RielaNoteUIClient) {
    self.client = client
    workflowRoot = client.defaultConfigWorkflowRoot
  }

  public var canSubmit: Bool {
    !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state != .loading
  }

  public var isApplying: Bool {
    state == .loading
  }

  public var errorMessage: String? {
    if case let .failed(message) = state {
      return message
    }
    return nil
  }

  public func submitDraft() async {
    let message = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty, state != .loading else {
      return
    }
    draftMessage = ""
    state = .loading
    do {
      proposals.append(try await client.proposeNoteConfigAgentChange(message: message))
      state = .loaded
    } catch {
      // Restore the typed request so a transient failure does not lose it.
      draftMessage = message
      state = .failed(String(describing: error))
    }
  }

  public func applyProposal(id: String) async {
    guard state != .loading else {
      return
    }
    guard let index = proposals.firstIndex(where: { $0.id == id }) else {
      return
    }
    state = .loading
    do {
      let result = try await client.applyNoteConfigAgentProposal(
        proposals[index],
        workflowRoot: workflowRoot
      )
      proposals[index].appliedResult = result
      state = .loaded
    } catch {
      state = .failed(String(describing: error))
    }
  }
}
