import Foundation

public struct NoteWorkflowScaffoldFile: Codable, Equatable, Sendable {
  public var relativePath: String
  public var path: String

  public init(relativePath: String, path: String) {
    self.relativePath = relativePath
    self.path = path
  }
}

public struct NoteIngestionWorkflowScaffoldResult: Codable, Equatable, Sendable {
  public var workflowId: String
  public var workflowRoot: String
  public var workflowPath: String
  public var files: [NoteWorkflowScaffoldFile]

  public init(
    workflowId: String,
    workflowRoot: String,
    workflowPath: String,
    files: [NoteWorkflowScaffoldFile]
  ) {
    self.workflowId = workflowId
    self.workflowRoot = workflowRoot
    self.workflowPath = workflowPath
    self.files = files
  }
}

public struct NoteIngestionWorkflowScaffolder: Sendable {
  public init() {}

  public func scaffold(
    workflowRoot rawWorkflowRoot: String,
    workflowId rawWorkflowId: String,
    notebookKindTag: String = "notebook-kind:imported-material",
    assignedBy: String = "note-config-agent"
  ) throws -> NoteIngestionWorkflowScaffoldResult {
    let workflowRoot = NSString(string: rawWorkflowRoot).expandingTildeInPath
    let workflowId = rawWorkflowId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isSafeWorkflowId(workflowId) else {
      throw NoteServiceError.invalidInput("workflow id must contain lowercase letters, numbers, and dashes")
    }
    guard !workflowRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw NoteServiceError.invalidInput("workflow root is required")
    }

    let bundleURL = URL(fileURLWithPath: workflowRoot, isDirectory: true)
      .appendingPathComponent(workflowId, isDirectory: true)
    let nodesURL = bundleURL.appendingPathComponent("nodes", isDirectory: true)
    try FileManager.default.createDirectory(at: nodesURL, withIntermediateDirectories: true)

    let workflowJSON = try prettyJSON(workflowObject(
      workflowId: workflowId,
      notebookKindTag: notebookKindTag,
      assignedBy: assignedBy
    ))
    let outputNodeJSON = try prettyJSON(outputNodeObject())
    let files = [
      try write(workflowJSON, relativePath: "workflow.json", bundleURL: bundleURL),
      try write(outputNodeJSON, relativePath: "nodes/node-workflow-output.json", bundleURL: bundleURL)
    ]
    return NoteIngestionWorkflowScaffoldResult(
      workflowId: workflowId,
      workflowRoot: workflowRoot,
      workflowPath: bundleURL.appendingPathComponent("workflow.json").path,
      files: files
    )
  }

  private func isSafeWorkflowId(_ workflowId: String) -> Bool {
    guard workflowId.count >= 2, workflowId.count <= 64 else {
      return false
    }
    return workflowId.unicodeScalars.allSatisfy { scalar in
      ("a"..."z").contains(Character(scalar)) ||
        ("0"..."9").contains(Character(scalar)) ||
        scalar == "-"
    }
  }

  private func workflowObject(
    workflowId: String,
    notebookKindTag: String,
    assignedBy: String
  ) -> [String: Any] {
    [
      "workflowId": workflowId,
      "description": "Ingest pages into Riela Note using the note config agent scaffold.",
      "defaults": [
        "maxLoopIterations": 3,
        "nodeTimeoutMs": 120_000
      ],
      "entryStepId": "ingest-pages",
      "nodes": [
        [
          "id": "ingest-pages",
          "addon": [
            "name": "riela/notebook-ingest-pages",
            "version": "1",
            "config": [
              "noteRoot": "{{noteRoot}}",
              "notebookTitle": "{{workflowInput.title}}",
              "sourceDocumentRef": "{{workflowInput.sourceDocumentRef}}",
              "notebookKindTag": notebookKindTag,
              "assignedBy": assignedBy
            ]
          ]
        ],
        [
          "id": "workflow-output",
          "kind": "output",
          "nodeFile": "nodes/node-workflow-output.json"
        ]
      ],
      "steps": [
        [
          "id": "ingest-pages",
          "nodeId": "ingest-pages",
          "role": "worker",
          "transitions": [["toStepId": "workflow-output"]]
        ],
        [
          "id": "workflow-output",
          "nodeId": "workflow-output",
          "role": "worker"
        ]
      ]
    ]
  }

  private func outputNodeObject() -> [String: Any] {
    [
      "id": "workflow-output",
      "description": "Project the notebook ingestion result as workflow output.",
      "executionBackend": "codex-agent",
      "model": "gpt-5.5",
      "modelFreeze": false,
      "promptTemplate": "Project the latest notebook ingest payload.",
      "variables": [:],
      "output": [
        "description": "Latest notebook ingestion payload.",
        "projection": ["kind": "latest-input-payload"]
      ]
    ]
  }

  private func prettyJSON(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    guard let string = String(data: data, encoding: .utf8) else {
      throw NoteServiceError.invalidInput("failed to encode workflow JSON")
    }
    return "\(string)\n"
  }

  private func write(
    _ content: String,
    relativePath: String,
    bundleURL: URL
  ) throws -> NoteWorkflowScaffoldFile {
    let url = bundleURL.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try content.write(to: url, atomically: true, encoding: .utf8)
    return NoteWorkflowScaffoldFile(relativePath: relativePath, path: url.path)
  }
}
