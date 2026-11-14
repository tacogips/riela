import Foundation

func validateMemoryDeclarations(
  _ memories: [WorkflowMemoryDeclaration]?,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let memories else {
    return
  }
  if memories.isEmpty {
    diagnostics.append(error(path, "must contain at least one memory when present"))
  }
  var seenIds: Set<String> = []
  for (index, memory) in memories.enumerated() {
    let memoryPath = "\(path)[\(index)]"
    validateMemoryId(memory.id, path: "\(memoryPath).id", diagnostics: &diagnostics)
    if !memory.id.isEmpty {
      if seenIds.contains(memory.id) {
        diagnostics.append(error("\(memoryPath).id", "must be unique within this memory declaration list"))
      }
      seenIds.insert(memory.id)
    }
    if let defaultLimit = memory.defaultLimit, defaultLimit <= 0 {
      diagnostics.append(error("\(memoryPath).defaultLimit", "must be a positive integer"))
    }
  }
}

func validateMemoryAddonDeclarations(
  _ node: WorkflowNodeRegistryRef,
  path: String,
  workflowMemoryIds: Set<String>,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let addon = node.addon else {
    return
  }
  let memoryIds = addonMemoryIds(addon)
  guard !memoryIds.isEmpty else {
    return
  }
  let nodeMemoryIds = Set((node.memories ?? []).map(\.id))
  for memoryId in memoryIds {
    if !workflowMemoryIds.contains(memoryId) {
      diagnostics.append(
        error(
          "\(path).addon.config.memoryId",
          "memory addon uses '\(memoryId)' but workflow.memories does not declare it"
        )
      )
    }
    if !nodeMemoryIds.contains(memoryId) {
      diagnostics.append(
        error(
          "\(path).memories",
          "memory addon uses '\(memoryId)' but node memories do not declare it"
        )
      )
    }
  }
}

func validateRawMemoryDeclarations(
  _ rawMemories: Any?,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let rawMemories else {
    return
  }
  guard let memories = rawMemories as? [Any] else {
    diagnostics.append(error(path, "must be an array"))
    return
  }
  if memories.isEmpty {
    diagnostics.append(error(path, "must contain at least one memory when present"))
  }
  var seenIds: Set<String> = []
  for (index, rawMemory) in memories.enumerated() {
    let memoryPath = "\(path)[\(index)]"
    guard let memory = rawMemory as? [String: Any] else {
      diagnostics.append(error(memoryPath, "must be an object"))
      continue
    }
    let allowedKeys: Set<String> = ["id", "description", "purpose", "dataSchema", "scope", "defaultLimit"]
    for key in memory.keys where !allowedKeys.contains(key) {
      diagnostics.append(error("\(memoryPath).\(key)", "uses an unsupported memory declaration field"))
    }
    if let id = memory["id"] as? String {
      validateMemoryId(id, path: "\(memoryPath).id", diagnostics: &diagnostics)
      if !id.isEmpty {
        if seenIds.contains(id) {
          diagnostics.append(error("\(memoryPath).id", "must be unique within this memory declaration list"))
        }
        seenIds.insert(id)
      }
    } else {
      diagnostics.append(error("\(memoryPath).id", "must be a non-empty string"))
    }
    if let scope = memory["scope"] as? String, WorkflowMemoryScope(rawValue: scope) == nil {
      diagnostics.append(error("\(memoryPath).scope", "must be workflow, node, or cross-workflow"))
    }
    if let defaultLimit = memory["defaultLimit"] {
      validatePositiveInteger(defaultLimit, path: "\(memoryPath).defaultLimit", diagnostics: &diagnostics)
    }
  }
}

private let simpleMemoryAddonNames: Set<String> = [
  "riela/memory-save",
  "riela/memory-update",
  "riela/memory-load",
  "riela/memory-search"
]

private let personaMemoryAddonNames: Set<String> = [
  "riela/chat-persona-memory-read",
  "riela/chat-persona-memory-write"
]

private let defaultMemoryId = "chat-memory"
private let defaultPersonaMemoryId = "persona-chat-memory"

private func addonMemoryIds(_ addon: WorkflowNodeAddonRef) -> [String] {
  if simpleMemoryAddonNames.contains(addon.name) {
    return [stringValue(addon.config?["memoryId"]) ?? defaultMemoryId]
  }
  if personaMemoryAddonNames.contains(addon.name) {
    return [stringValue(addon.config?["memoryId"]) ?? defaultPersonaMemoryId]
  }
  return []
}

private func stringValue(_ value: JSONValue?) -> String? {
  guard case let .string(value) = value, !value.isEmpty else {
    return nil
  }
  return value
}

private func validateMemoryId(_ value: String, path: String, diagnostics: inout [WorkflowValidationDiagnostic]) {
  guard !value.isEmpty else {
    diagnostics.append(error(path, "must be a non-empty string"))
    return
  }
  if value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) == nil {
    diagnostics.append(error(path, "must start with an alphanumeric character and contain only letters, digits, hyphens, underscores, or dots"))
  }
}
