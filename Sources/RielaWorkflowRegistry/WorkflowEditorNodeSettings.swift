import Foundation
import RielaCore

public struct WorkflowEditorNodeSettings: Codable, Sendable {
  public var assetRevision: String
  public var prompt: String?
  public var model: String?
  public var promptHidden: Bool
  public var modelHidden: Bool
}

extension WorkflowRegistryService {
  public func editorNodeSettings(target: WorkflowRegistryTarget, nodeId: String,
                                 definitionRevision: String, workingDirectory: String) throws -> WorkflowEditorNodeSettings {
    try withCoordinatedRead(workingDirectory: workingDirectory) {
      try requireEditorNodeTarget(target)
      let snapshot = try definitionSnapshot(target: target, workingDirectory: workingDirectory)
      guard snapshot.revision == definitionRevision else { throw editorNodeConflict() }
      let asset = try EditorNodeAsset(definition: snapshot.data, nodeId: nodeId,
        root: URL(fileURLWithPath: snapshot.entry.workflowDirectory))
      return asset.settings
    }
  }

  public func updateEditorNodeSettings(target: WorkflowRegistryTarget, nodeId: String,
                                       definitionRevision: String, assetRevision: String,
                                       prompt: String?, model: String?, workingDirectory: String) throws -> WorkflowRegistryMutationResult {
    try requireEditorNodeTarget(target)
    return try updateBundleDefinition(target: target, expectedDefinitionRevision: definitionRevision,
      workingDirectory: workingDirectory) { definition, _, workspace in
      let asset = try EditorNodeAsset(definition: definition, nodeId: nodeId, root: workspace)
      guard asset.settings.assetRevision == assetRevision else { throw editorNodeConflict() }
      guard prompt != nil || model != nil else { throw editorNodeInvalid("Change a prompt or model before saving.") }
      var payload = asset.payload
      if let prompt { payload["promptTemplate"] = .string(prompt); payload.removeValue(forKey: "promptTemplateFile") }
      if let model {
        if model.isEmpty { payload.removeValue(forKey: "model") } else { payload["model"] = .string(model) }
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(payload)
      guard data.count <= 524_288 else { throw editorNodeInvalid("Node settings exceed 512 KiB.") }
      // Copy-on-write changes the workflow reference/revision atomically and
      // never rewrites a node or prompt file shared by another node.
      let relative = "editor-node-\(WorkflowHistoryCanonicalCoding.sha256(data)).json"
      let destination = workspace.appendingPathComponent(relative)
      if FileManager.default.fileExists(atPath: destination.path) {
        guard try Data(contentsOf: destination) == data else { throw editorNodeInvalid("The generated node file conflicts with an existing resource.") }
      } else {
        try data.write(to: destination, options: .withoutOverwriting)
      }
      var document = asset.definition
      var nodes = asset.nodes
      var node = asset.node
      node["nodeFile"] = .string(relative)
      nodes[asset.index] = .object(node)
      document["nodes"] = .array(nodes)
      return try encoder.encode(document)
    }
  }
}

private struct EditorNodeAsset {
  let definition: JSONObject
  let nodes: [JSONValue]
  let node: JSONObject
  let index: Int
  let payload: JSONObject
  let settings: WorkflowEditorNodeSettings

  init(definition data: Data, nodeId: String, root: URL) throws {
    definition = try JSONDecoder().decode(JSONObject.self, from: data)
    guard case let .array(nodes)? = definition["nodes"],
          let index = nodes.firstIndex(where: { value in
            guard case let .object(node) = value else { return false }; return node["id"] == .string(nodeId)
          }), case let .object(node) = nodes[index], case let .string(path)? = node["nodeFile"] else {
      throw editorNodeInvalid("Select a file-backed node in a saved mutable workflow.")
    }
    self.nodes = nodes; self.index = index; self.node = node
    let bytes = try editorNodeRead(path: path, root: root)
    payload = try JSONDecoder().decode(JSONObject.self, from: bytes)
    guard payload["executionBackend"] != nil || payload["promptTemplate"] != nil || payload["promptTemplateFile"] != nil else {
      throw editorNodeInvalid("This node does not have agent prompt/model settings.")
    }
    var prompt: String?
    var promptBytes = Data()
    if case let .string(file)? = payload["promptTemplateFile"] {
      promptBytes = try editorNodeRead(path: file, root: root)
      guard let text = String(data: promptBytes, encoding: .utf8) else { throw editorNodeInvalid("The prompt must be UTF-8 text.") }
      prompt = text
    } else if case let .string(text)? = payload["promptTemplate"] { prompt = text }
    var model: String?
    if case let .string(value)? = payload["model"] { model = value }
    let visiblePrompt = editorNodeDisplay(prompt)
    let visibleModel = editorNodeDisplay(model)
    settings = WorkflowEditorNodeSettings(
      assetRevision: WorkflowHistoryCanonicalCoding.sha256(Data((WorkflowHistoryCanonicalCoding.sha256(bytes)
        + ":" + WorkflowHistoryCanonicalCoding.sha256(promptBytes)).utf8)),
      prompt: visiblePrompt, model: visibleModel,
      promptHidden: prompt != nil && visiblePrompt == nil, modelHidden: model != nil && visibleModel == nil)
  }
}

private func editorNodeRead(path: String, root: URL) throws -> Data {
  guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
        !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
    throw editorNodeInvalid("Node resources must remain inside the workflow bundle.")
  }
  let base = root.resolvingSymlinksInPath().standardizedFileURL
  let url = base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
  guard url.path.hasPrefix(base.path + "/") else { throw editorNodeInvalid("Node resource escaped the workflow bundle.") }
  let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
  guard values.isRegularFile == true, let size = values.fileSize, size <= 524_288 else {
    throw editorNodeInvalid("Node resources must be regular files below 512 KiB.")
  }
  let data = try Data(contentsOf: url)
  guard data.count <= 524_288 else { throw editorNodeInvalid("Node resource exceeds 512 KiB.") }
  return data
}

private func editorNodeDisplay(_ text: String?) -> String? {
  guard let text else { return nil }
  let projected = WorkflowWebProjectionPolicy().displayText(text)
  return projected.value == "<redacted>" || projected.truncated ? nil : text
}

private func requireEditorNodeTarget(_ target: WorkflowRegistryTarget) throws {
  guard target.scope == .user, let origin = target.originId, !origin.isEmpty else {
    throw editorNodeInvalid("An exact user mutable workflow is required.")
  }
}

private func editorNodeInvalid(_ message: String) -> WorkflowRegistryError {
  WorkflowRegistryError(code: .invalidWorkflow, message: message)
}

private func editorNodeConflict() -> WorkflowRegistryError {
  WorkflowRegistryError(code: .registryConflict, message: "The workflow or node resources changed. Reload before editing settings.")
}
