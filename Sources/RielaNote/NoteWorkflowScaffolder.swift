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
    assignedBy: String = "note-config-agent",
    translationEnabled: Bool = false
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
      assignedBy: assignedBy,
      translationEnabled: translationEnabled
    ))
    let ocrNodeJSON = try prettyJSON(ocrNodeObject(translationEnabled: translationEnabled))
    let translateNodeJSON = try prettyJSON(translateNodeObject())
    let outputNodeJSON = try prettyJSON(outputNodeObject())
    let ocrPrompt = ocrPromptTemplate()
    let translatePrompt = translatePromptTemplate()
    let files = [
      try write(workflowJSON, relativePath: "workflow.json", bundleURL: bundleURL),
      try write(ocrNodeJSON, relativePath: "nodes/node-ocr-pages.json", bundleURL: bundleURL),
      try write(translateNodeJSON, relativePath: "nodes/node-translate-pages.json", bundleURL: bundleURL),
      try write(ocrPrompt, relativePath: "prompts/ocr-pages.md", bundleURL: bundleURL),
      try write(translatePrompt, relativePath: "prompts/translate-pages.md", bundleURL: bundleURL),
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
    assignedBy: String,
    translationEnabled: Bool
  ) -> [String: Any] {
    [
      "workflowId": workflowId,
      "description": "OCR source images, optionally translate OCR text, then ingest pages into Riela Note.",
      "defaults": [
        "maxLoopIterations": 3,
        "nodeTimeoutMs": 120_000
      ],
      "entryStepId": "ocr-pages",
      "nodes": [
        [
          "id": "ocr-pages",
          "nodeFile": "nodes/node-ocr-pages.json"
        ],
        [
          "id": "translate-pages",
          "nodeFile": "nodes/node-translate-pages.json"
        ],
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
              "assignedBy": assignedBy,
              "translationEnabled": translationEnabled
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
          "id": "ocr-pages",
          "nodeId": "ocr-pages",
          "role": "worker",
          "transitions": [
            [
              "toStepId": "translate-pages",
              "label": "needs_translation"
            ],
            [
              "toStepId": "ingest-pages",
              "label": "!(needs_translation)"
            ]
          ]
        ],
        [
          "id": "translate-pages",
          "nodeId": "translate-pages",
          "role": "worker",
          "transitions": [["toStepId": "ingest-pages"]]
        ],
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

  private func ocrNodeObject(translationEnabled: Bool) -> [String: Any] {
    [
      "id": "ocr-pages",
      "description": "OCR source images and return note-ready page drafts without translation.",
      "executionBackend": "official-openai-sdk",
      "model": "gpt-5",
      "modelFreeze": false,
      "promptTemplateFile": "prompts/ocr-pages.md",
      "variables": [
        "translationEnabledDefault": translationEnabled
      ],
      "output": [
        "description": "OCR page drafts and a needs_translation routing flag."
      ]
    ]
  }

  private func translateNodeObject() -> [String: Any] {
    [
      "id": "translate-pages",
      "description": "Translate OCR page drafts and keep original OCR text with translated text.",
      "executionBackend": "official-openai-sdk",
      "model": "gpt-5",
      "modelFreeze": false,
      "promptTemplateFile": "prompts/translate-pages.md",
      "variables": [:],
      "output": [
        "description": "Translated page drafts accepted by riela/notebook-ingest-pages."
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

  private func ocrPromptTemplate() -> String {
    """
    OCR the source image attachments for Riela Note ingestion.

    Inputs:
    - title: {{workflowInput.title}}
    - sourceDocumentRef: {{workflowInput.sourceDocumentRef}}
    - imagePaths: {{workflowInput.imagePaths}}
    - translation: {{workflowInput.translation}}
    - translationEnabledDefault: {{translationEnabledDefault}}

    Return JSON only in this envelope:
    {
      "payload": {
        "status": "ready",
        "needs_translation": false,
        "pages": [
          {
            "title": "Page 1",
            "bodyMarkdown": "OCR text only. Do not translate.",
            "readOnly": false,
            "tags": [],
            "meta": {"ocrText": "same OCR text"}
          }
        ]
      },
      "when": {"needs_translation": false}
    }

    Rules:
    - Extract exact visible text from the attachments.
    - Do not translate in this step.
    - Preserve page order.
    - Set needs_translation to true when workflowInput.translation.enabled is exactly true.
    - If workflowInput.translation.enabled is absent, set needs_translation to translationEnabledDefault.
    - Use the same boolean value in payload.needs_translation and when.needs_translation.
    - If translation is disabled, bodyMarkdown must contain the OCR text alone.
    """
  }

  private func translatePromptTemplate() -> String {
    """
    Translate OCR page drafts for Riela Note ingestion.

    Inputs:
    - target language: {{workflowInput.translation.targetLanguage}}
    - OCR pages: {{inbox.latest.output.payload.pages}}

    Return JSON only:
    {
      "status": "ready",
      "pages": [
        {
          "title": "Page 1",
          "bodyMarkdown": "OCR:\\n<original OCR text>\\n\\nTranslation:\\n<translated text>",
          "readOnly": false,
          "tags": [],
          "meta": {"ocrText": "<original OCR text>", "translationText": "<translated text>"}
        }
      ]
    }

    Rules:
    - Translate only from the provided OCR text.
    - Do not inspect images or redo OCR in this step.
    - Keep original OCR text and translated text together in bodyMarkdown.
    - Preserve page order and existing page metadata where possible.
    """
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
