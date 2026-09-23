import Foundation

func validateDistributedPlacement(_ placement: DistributedExecutionPlacement, path: String, diagnostics: inout [WorkflowValidationDiagnostic]) {
  var target: [String: String] = [:]
  target["workerId"] = placement.target.workerId
  target["group"] = placement.target.group
  var value: [String: Any] = ["workspace": placement.workspace, "target": target]
  value["exports"] = placement.exports
  validateDistributedPlacement(value, path: path, diagnostics: &diagnostics)
}

func validateDistributedPlacement(_ value: Any, path: String, diagnostics: inout [WorkflowValidationDiagnostic]) {
  guard let placement = value as? [String: Any],
    Set(placement.keys).isSubset(of: ["target", "workspace", "exports"]),
    let workspace = placement["workspace"] as? String, validDistributedName(workspace),
    let target = placement["target"] as? [String: Any], Set(target.keys).isSubset(of: ["workerId", "group"]),
    target.values.allSatisfy({ ($0 as? String).map(validDistributedName) == true }) else {
    diagnostics.append(WorkflowValidationDiagnostic(
      severity: .error, path: path,
      message: "requires workspace and target; target accepts non-empty workerId and/or group strings, or {} for any remote worker"
    ))
    return
  }
  if let exports = placement["exports"] {
    guard let paths = exports as? [String], (try? DistributedArtifact.validatePaths(paths)) != nil else {
      diagnostics.append(WorkflowValidationDiagnostic(
        severity: .error, path: path + ".exports", message: "requires at most 16 unique workspace-relative file paths without traversal"
      ))
      return
    }
  }
}

private func validDistributedName(_ name: String) -> Bool {
  !name.isEmpty && name.utf8.count <= 256 && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
    && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
}
