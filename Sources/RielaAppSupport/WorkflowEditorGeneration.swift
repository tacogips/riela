import Foundation
import RielaCore

public enum WorkflowEditorGenerationStatus: String, Codable, Sendable {
  case running, completed, failed, cancelled
}

public struct WorkflowEditorGenerationSnapshot: Codable, Sendable {
  public var id: String
  public var profile: String
  public var revision: Int
  public var status: WorkflowEditorGenerationStatus
  public var definition: JSONObject
  public var messages: [String]
  public var error: String?
}

/// Incremental NDJSON authoring protocol. Snapshots are isolated from the registry;
/// only the editor's normal revision-checked save can publish a definition.
public actor WorkflowEditorGenerationStore {
  public enum GenerationError: Error { case capacityExceeded }
  public typealias Runner = @Sendable (@escaping AdapterBackendEventHandler) async throws -> String
  private struct Session {
    var snapshot: WorkflowEditorGenerationSnapshot
    var task: Task<Void, Never>?
    var text = ""
    var parsedLines: [String] = []
    var streamedLines: [String] = []
    var changed = false
    var createdAt = Date()
  }
  private var sessions: [String: Session] = [:]
  public init() {}

  public func start(profile: String, definition: JSONObject, runner: @escaping Runner) throws -> WorkflowEditorGenerationSnapshot {
    sessions = sessions.filter { _, session in
      session.snapshot.status == .running || Date().timeIntervalSince(session.createdAt) < 3600
    }
    guard sessions.values.filter({ $0.snapshot.status == .running }).count < 4, sessions.count < 40 else {
      throw GenerationError.capacityExceeded
    }
    let id = UUID().uuidString.lowercased()
    let snapshot = WorkflowEditorGenerationSnapshot(
      id: id, profile: profile, revision: 0, status: .running, definition: definition, messages: []
    )
    sessions[id] = Session(snapshot: snapshot)
    sessions[id]?.task = Task {
      do {
        let output = try await runner { event in await self.receive(id: id, event: event) }
        self.finish(id: id, output: output)
      } catch let error as WorkflowEditorAuthoringRounds.AuthoringError {
        let message: String
        switch error {
        case .invalidProtocol: message = "The agent did not return a complete editing-round protocol. Retry from the current draft."
        case .outputLimit: message = "Agent generation exceeded the output limit. Continue with a smaller request."
        case .roundLimit: message = "The agent reached the 12-round limit. Review the draft and continue with another request."
        }
        self.fail(id: id, message: message)
      } catch {
        self.fail(id: id, message: "Agent generation failed. Check the assistant provider settings and retry.")
      }
    }
    return snapshot
  }

  public func snapshot(id: String, profile: String) -> WorkflowEditorGenerationSnapshot? {
    guard sessions[id]?.snapshot.profile == profile else { return nil }
    return sessions[id]?.snapshot
  }

  public func cancel(id: String, profile: String) -> WorkflowEditorGenerationSnapshot? {
    guard sessions[id]?.snapshot.profile == profile else { return nil }
    sessions[id]?.task?.cancel()
    sessions[id]?.task = nil
    sessions[id]?.snapshot.status = .cancelled
    return sessions[id]?.snapshot
  }

  public func cancelAll() {
    for id in Array(sessions.keys) {
      guard sessions[id]?.snapshot.status == .running, let profile = sessions[id]?.snapshot.profile else { continue }
      _ = cancel(id: id, profile: profile)
    }
  }

  private func receive(id: String, event: AdapterBackendEvent) {
    guard event.channel == .assistant, sessions[id]?.snapshot.status == .running else { return }
    if let delta = event.contentDelta, event.isDelta {
      sessions[id]?.text += delta
    } else if let snapshot = event.contentSnapshot {
      sessions[id]?.text = snapshot
    } else if let delta = event.contentDelta {
      sessions[id]?.text += delta
    }
    guard let text = sessions[id]?.text else { return }
    if text.utf8.count > 1_048_576 {
      sessions[id]?.task?.cancel()
      fail(id: id, message: "Agent output exceeded the editor limit.")
      return
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    let previous = sessions[id]?.parsedLines ?? []
    let prefix = zip(previous, lines).prefix { $0 == $1 }.count
    for line in lines.dropFirst(prefix) {
      consume(id: id, line: line)
      sessions[id]?.streamedLines.append(line)
    }
    sessions[id]?.parsedLines = lines
  }

  private func finish(id: String, output: String) {
    guard sessions[id]?.snapshot.status == .running else { return }
    let text = output.isEmpty ? sessions[id]?.text ?? "" : output
    guard text.utf8.count <= 1_048_576 else { fail(id: id, message: "Agent output exceeded the editor limit."); return }
    let lines = text.split(separator: "\n").map(String.init)
    let streamed = (sessions[id]?.streamedLines ?? []).filter { !$0.isEmpty }
    // Providers may return the complete transcript or only the final message.
    // Deduplicate the replay by sequence, never by record content: A→B→A is a
    // legitimate revision history and must finish at A.
    if Array(streamed.suffix(lines.count)) != lines {
      let prefix = zip(streamed, lines).prefix { $0 == $1 }.count
      for line in lines.dropFirst(prefix) { consume(id: id, line: line) }
    }
    if sessions[id]?.changed != true && sessions[id]?.snapshot.messages.isEmpty != false {
      fail(id: id, message: "The agent did not return editor operations. Try a more specific request.")
    } else {
      sessions[id]?.snapshot.status = .completed
      sessions[id]?.task = nil
    }
  }

  private func consume(id: String, line: String) {
    guard var session = sessions[id],
          let data = line.data(using: .utf8),
          let record = try? JSONDecoder().decode(JSONObject.self, from: data),
          case let .string(type) = record["type"] else { return }
    if type == "message", case let .string(message) = record["text"] {
      session.snapshot.messages.append(String(message.prefix(4000)))
      session.snapshot.messages = Array(session.snapshot.messages.suffix(40))
    } else if type == "definition", case let .object(definition) = record["definition"],
              case .string = definition["workflowId"], case .array = definition["nodes"],
              case .array = definition["steps"] {
      session.snapshot.definition = definition
      session.changed = true
    } else {
      return
    }
    session.snapshot.revision += 1
    sessions[id] = session
  }

  private func fail(id: String, message: String) {
    guard sessions[id]?.snapshot.status == .running else { return }
    sessions[id]?.snapshot.status = .failed
    sessions[id]?.snapshot.error = message
    sessions[id]?.task = nil
  }
}
