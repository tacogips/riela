import Foundation

public enum TemplateSurface: Equatable, Sendable {
  case addonConfig(addonInputKeys: Set<String>)
  case addonInputs
}

public enum TemplateReferenceClass: Equatable, Sendable {
  case payload
  case context
}

public func classifyTemplateReference(
  _ path: String,
  surface: TemplateSurface
) -> TemplateReferenceClass {
  let components = templatePathComponents(path)
  guard let root = components.first else { return .context }

  if root == "inbox" {
    return components.starts(with: ["inbox", "latest", "output", "payload"])
      && components.count > 4 ? .payload : .context
  }
  if root == "input" {
    guard components.count > 1 else { return .context }
    return ["_rielaInput", "upstream", "runtime"].contains(components[1]) ? .context : .payload
  }
  let reservedRoots: Set<String> = [
    "event", "workflowInput", "runtime", "upstream", "_rielaInput",
    "workflowId", "stepId", "nodeId", "addonName"
  ]
  if reservedRoots.contains(root) { return .context }
  if case let .addonConfig(addonInputKeys) = surface, addonInputKeys.contains(root) {
    return .context
  }
  return .payload
}

public func templateReferencePaths(in value: JSONValue) -> [String] {
  switch value {
  case let .string(template):
    return templatePaths(in: template)
  case let .array(values):
    return values.flatMap(templateReferencePaths)
  case let .object(object):
    return object.keys.sorted().flatMap { templateReferencePaths(in: object[$0] ?? .null) }
  case .null, .bool, .integer, .number:
    return []
  }
}

public func payloadField(
  inTemplatePath path: String,
  surface: TemplateSurface
) -> String? {
  guard classifyTemplateReference(path, surface: surface) == .payload else { return nil }
  let components = templatePathComponents(path)
  if components.first == "inbox" { return components.count > 4 ? components[4] : nil }
  if components.first == "input" { return components.count > 1 ? components[1] : nil }
  return components.first
}

private func templatePathComponents(_ path: String) -> [String] {
  path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
}

private func templatePaths(in template: String) -> [String] {
  let pattern = #"\{\{\s*([a-zA-Z0-9_.-]+)\s*\}\}"#
  guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
  let range = NSRange(template.startIndex..<template.endIndex, in: template)
  return regex.matches(in: template, range: range).compactMap { match in
    guard let pathRange = Range(match.range(at: 1), in: template) else { return nil }
    return String(template[pathRange])
  }
}
