import Foundation
import RielaCore
import RielaKaibaAddons
import RielaWork

protocol KaibaHandoverNoteClient: Sendable {
  func createNote(instanceId: String, notebookId: String?, title: String, bodyMarkdown: String, tags: [String]) async throws -> String
  func getNote(instanceId: String, noteId: String) async throws -> String
}

struct KaibaHandoverSink: HandoverSink {
  let client: any KaibaHandoverNoteClient
  let instanceId: String
  let notebookId: String?
  let kind: HandoverSinkKind = .kaiba

  init(client: any KaibaHandoverNoteClient, instanceId: String, notebookId: String? = nil) {
    self.client = client
    self.instanceId = instanceId
    self.notebookId = notebookId
  }

  func write(_ packet: HandoverPacket, bytes: Data, brief: String) async throws -> HandoverSinkRef {
    guard let json = String(data: bytes, encoding: .utf8) else { throw HandoverSinkError.invalidPacketEncoding }
    let body = brief + "\n\n```riela-handover-packet\n" + json + "\n```\n"
    let title = "Handover \(packet.id.rawValue) (\(packet.taskId.rawValue))"
    let noteId = try await client.createNote(
      instanceId: instanceId,
      notebookId: notebookId,
      title: title,
      bodyMarkdown: body,
      tags: ["riela-handover", "task:\(packet.taskId.rawValue)"]
    )
    guard !noteId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw HandoverSinkError.invalidCommandOutput
    }
    return HandoverSinkRef(kind: kind, locator: "\(instanceId)/\(noteId)", digest: packet.digest, writtenAt: Date())
  }

  func read(_ ref: HandoverSinkRef) async throws -> Data {
    guard ref.kind == kind else { throw HandoverSinkError.invalidLocator(ref.locator) }
    let pieces = ref.locator.split(separator: "/", omittingEmptySubsequences: false)
    guard pieces.count == 2, String(pieces[0]) == instanceId, !pieces[1].isEmpty else {
      throw HandoverSinkError.invalidLocator(ref.locator)
    }
    let body = try await client.getNote(instanceId: instanceId, noteId: String(pieces[1]))
    let opening = "```riela-handover-packet\n"
    guard let start = body.range(of: opening), let end = body[start.upperBound...].range(of: "\n```") else {
      throw HandoverSinkError.packetBlockMissing
    }
    return Data(body[start.upperBound..<end.lowerBound].utf8)
  }
}

struct KaibaAddonCatalogNoteClient: KaibaHandoverNoteClient {
  let environment: [String: String]

  func createNote(instanceId: String, notebookId: String?, title: String, bodyMarkdown: String, tags: [String]) async throws -> String {
    var inputs: JSONObject = ["title": .string(title), "bodyMarkdown": .string(bodyMarkdown), "tags": .array(tags.map(JSONValue.string))]
    if let notebookId { inputs["notebookId"] = .string(notebookId) }
    let addonInput = input("kaiba/note-create", instanceId: instanceId, inputs: inputs)
    let output = try await execute(addonInput)
    guard let noteId = output.payload["noteId"]?.stringValue else {
      throw HandoverSinkError.kaibaResponseInvalid("note-create did not return noteId")
    }
    return noteId
  }

  func getNote(instanceId: String, noteId: String) async throws -> String {
    let addonInput = input("kaiba/note-get", instanceId: instanceId, inputs: ["noteId": .string(noteId)])
    let output = try await execute(addonInput)
    guard case let .object(note)? = output.payload["note"],
          let body = note["bodyMarkdown"]?.stringValue else {
      throw HandoverSinkError.kaibaResponseInvalid("note-get did not return note bodyMarkdown")
    }
    return body
  }

  private func input(_ addonName: String, instanceId: String, inputs: JSONObject) -> WorkflowAddonExecutionInput {
    WorkflowAddonExecutionInput(
      workflowId: "handover-sink",
      stepId: "handover-sink",
      nodeId: "handover-sink",
      addon: WorkflowNodeAddonRef(
        name: addonName,
        config: ["kaibaInstanceId": .string(instanceId)],
        inputs: inputs
      ),
      variables: inputs,
      resolvedInputPayload: inputs
    )
  }

  private func execute(_ input: WorkflowAddonExecutionInput) async throws -> AdapterExecutionOutput {
    if let snapshot = KaibaAddonExecutionContext.snapshot {
      return try await KaibaAddonExecutionContext.withSnapshot(snapshot, allowsMockExecution: false) {
        try await KaibaAddonCatalog.execute(input, environment: environment)
      }
    }
    let snapshot = try await KaibaExecutionPreflight.direct(addon: input.addon, environment: environment)
    return try await KaibaAddonExecutionContext.withSnapshot(snapshot, allowsMockExecution: false) {
      try await KaibaAddonCatalog.execute(input, environment: environment)
    }
  }
}
