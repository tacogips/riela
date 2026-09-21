import Foundation

public struct WorkflowInheritanceDeclaration: Equatable, Sendable {
  public var derivedWorkflowId: String
  public var description: String?
  public var baseWorkflowId: String
  public var stringReplacements: [String: String]
  public var agentNodePatch: WorkflowInstanceNodePatch?
  public var nodePatches: [String: WorkflowInstanceNodePatch]

  public static func parse(data: Data) throws -> WorkflowInheritanceDeclaration? {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      return nil
    }
    guard let raw = object as? [String: Any], raw.keys.contains("extends") else { return nil }
    var diagnostics: [WorkflowValidationDiagnostic] = []
    let allowedTopLevel: Set<String> = ["workflowId", "description", "extends"]
    for key in raw.keys where !allowedTopLevel.contains(key) {
      diagnostics.append(diagnostic("workflow.\(key)", "is not supported on a derived workflow"))
    }
    let derivedId = validatedIdentifier(raw["workflowId"], path: "workflow.workflowId", diagnostics: &diagnostics)
    var description: String?
    if let value = raw["description"] {
      if let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        description = string
      } else {
        diagnostics.append(diagnostic("workflow.description", "must be a non-empty string when provided"))
      }
    }
    guard let inherited = raw["extends"] as? [String: Any] else {
      diagnostics.append(diagnostic("workflow.extends", "must be an object"))
      throw WorkflowInheritanceError.invalidDeclaration(diagnostics)
    }
    let allowedInheritance: Set<String> = ["workflowId", "stringReplacements", "agentNodePatch", "nodePatch"]
    for key in inherited.keys where !allowedInheritance.contains(key) {
      diagnostics.append(diagnostic("workflow.extends.\(key)", "is not a supported inheritance field"))
    }
    let baseId = validatedIdentifier(
      inherited["workflowId"], path: "workflow.extends.workflowId", diagnostics: &diagnostics
    )
    let replacements = parseReplacements(inherited["stringReplacements"], diagnostics: &diagnostics)
    let agentPatch = parsePatch(
      inherited["agentNodePatch"], path: "workflow.extends.agentNodePatch", diagnostics: &diagnostics
    )
    let nodePatches = parseNodePatches(inherited["nodePatch"], diagnostics: &diagnostics)
    guard diagnostics.isEmpty, let derivedId, let baseId else {
      throw WorkflowInheritanceError.invalidDeclaration(diagnostics)
    }
    return WorkflowInheritanceDeclaration(
      derivedWorkflowId: derivedId,
      description: description,
      baseWorkflowId: baseId,
      stringReplacements: replacements,
      agentNodePatch: agentPatch,
      nodePatches: nodePatches
    )
  }
}

public enum WorkflowInheritanceError: Error, Equatable, Sendable {
  case invalidDeclaration([WorkflowValidationDiagnostic])
  case transformation([WorkflowValidationDiagnostic])
  case cycle([String])
  case missingBase(derivedWorkflowId: String, baseWorkflowId: String, searchedRoots: [String])
}

private extension WorkflowInheritanceDeclaration {
  static func validatedIdentifier(
    _ value: Any?, path: String, diagnostics: inout [WorkflowValidationDiagnostic]
  ) -> String? {
    guard let value = value as? String, !value.isEmpty else {
      diagnostics.append(diagnostic(path, "must be a non-empty string"))
      return nil
    }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted
    guard value.unicodeScalars.first.map(CharacterSet.alphanumerics.contains) == true,
          value.rangeOfCharacter(from: allowed) == nil else {
      diagnostics.append(diagnostic(path, "must be a safe workflow identifier"))
      return nil
    }
    return value
  }

  static func parseReplacements(
    _ value: Any?, diagnostics: inout [WorkflowValidationDiagnostic]
  ) -> [String: String] {
    guard let value else { return [:] }
    guard let raw = value as? [String: Any] else {
      diagnostics.append(diagnostic("workflow.extends.stringReplacements", "must be an object"))
      return [:]
    }
    var result: [String: String] = [:]
    for key in raw.keys.sorted() {
      guard !key.isEmpty else {
        diagnostics.append(diagnostic("workflow.extends.stringReplacements", "must not contain an empty source"))
        continue
      }
      guard let replacement = raw[key] as? String else {
        diagnostics.append(diagnostic("workflow.extends.stringReplacements.\(key)", "must be a string"))
        continue
      }
      result[key] = replacement
    }
    return result
  }

  static func parsePatch(
    _ value: Any?, path: String, diagnostics: inout [WorkflowValidationDiagnostic]
  ) -> WorkflowInstanceNodePatch? {
    guard let value else { return nil }
    guard let raw = value as? [String: Any] else {
      diagnostics.append(diagnostic(path, "must be an object"))
      return nil
    }
    do {
      return try WorkflowInstanceNodePatch(jsonObject: try jsonObject(raw), nodeId: path)
    } catch {
      diagnostics.append(diagnostic(path, "contains an unsupported field or invalid value: \(error)"))
      return nil
    }
  }

  static func parseNodePatches(
    _ value: Any?, diagnostics: inout [WorkflowValidationDiagnostic]
  ) -> [String: WorkflowInstanceNodePatch] {
    guard let value else { return [:] }
    guard let raw = value as? [String: Any] else {
      diagnostics.append(diagnostic("workflow.extends.nodePatch", "must be an object"))
      return [:]
    }
    var patches: [String: WorkflowInstanceNodePatch] = [:]
    for nodeId in raw.keys.sorted() {
      if let patch = parsePatch(
        raw[nodeId], path: "workflow.extends.nodePatch.\(nodeId)", diagnostics: &diagnostics
      ) {
        patches[nodeId] = patch
      }
    }
    return patches
  }

  static func jsonObject(_ raw: [String: Any]) throws -> JSONObject {
    let data = try JSONSerialization.data(withJSONObject: raw)
    return try JSONDecoder().decode(JSONObject.self, from: data)
  }

  static func diagnostic(_ path: String, _ message: String) -> WorkflowValidationDiagnostic {
    WorkflowValidationDiagnostic(severity: .error, path: path, message: message)
  }
}
