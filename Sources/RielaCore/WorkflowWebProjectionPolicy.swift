import Foundation

public struct WorkflowWebProjectedString: Equatable, Sendable {
  public var value: String
  public var truncated: Bool

  public init(value: String, truncated: Bool) {
    self.value = value
    self.truncated = truncated
  }
}

public enum WorkflowWebPersistedSummaryContext: Sendable {
  case diagnostic
  case stepFailure
  case gateFinding
  case recoveryReason
  case registryDiagnostic
}

public struct WorkflowWebProjectionPolicy: Sendable {
  public static let runDetailResponseLimit = 1_024 * 1_024
  public static let definitionResponseLimit = 512 * 1_024
  public static let identifierLimit = 256
  public static let summaryLimit = 2_048

  public init() {}

  public func identifier(_ value: String) -> WorkflowWebProjectedString {
    bounded(value, limit: Self.identifierLimit)
  }

  public func displayText(_ value: String) -> WorkflowWebProjectedString {
    let singleLine = singleLine(value)
    guard !containsSensitiveValue(singleLine) else {
      return WorkflowWebProjectedString(value: "<redacted>", truncated: false)
    }
    let withoutPaths = singleLine.replacingOccurrences(
      of: #"(?<![A-Za-z0-9._-])/(?:[^/\s]+/)*[^/\s]*"#,
      with: "<path>",
      options: .regularExpression
    )
    return bounded(withoutPaths, limit: Self.summaryLimit)
  }

  public func persistedSummary(
    _ value: String,
    context: WorkflowWebPersistedSummaryContext
  ) -> WorkflowWebProjectedString {
    let normalized = singleLine(value)
    guard !normalized.isEmpty else {
      return WorkflowWebProjectedString(value: "", truncated: false)
    }
    return bounded(
      synthesizedPersistedSummary(normalized, context: context),
      limit: Self.summaryLimit
    )
  }

  public func safeIdentifier(_ value: String) -> String {
    identifier(value).value
  }

  public func safeSummary(_ value: String) -> String {
    displayText(value).value
  }

  public func contentRevision(_ data: Data) -> String {
    WorkflowHistoryCanonicalCoding.sha256(data)
  }

  public func boundedRunDetail(_ object: JSONObject) -> JSONObject? {
    bounded(object, limit: Self.runDetailResponseLimit, reducer: reduceRunDetail)
  }

  public func boundedDefinition(_ object: JSONObject) -> JSONObject? {
    bounded(object, limit: Self.definitionResponseLimit, reducer: reduceDefinition)
  }

  private func bounded(
    _ object: JSONObject,
    limit: Int,
    reducer: (inout JSONObject) -> Bool
  ) -> JSONObject? {
    var bounded = object
    var attempts = 0
    while jsonSize(bounded) > limit, attempts < 64 {
      guard reducer(&bounded) else { break }
      attempts += 1
    }
    return jsonSize(bounded) <= limit ? bounded : nil
  }

  private func reduceRunDetail(_ object: inout JSONObject) -> Bool {
    if reduceNestedCollections(&object, parentKey: "steps", childKeys: ["events"]) {
      object["truncated"] = .bool(true)
      return true
    }
    if halveCollection(&object, key: "logs") {
      object["logsTruncated"] = .bool(true)
      object["truncated"] = .bool(true)
      return true
    }
    if reduceNestedCollections(
      &object,
      parentKey: "gates",
      childKeys: ["evidenceRefs", "diagnostics", "findings"]
    ) {
      object["truncated"] = .bool(true)
      return true
    }
    for key in ["diagnostics", "gates"] where halveCollection(&object, key: key) {
      object["\(key)Truncated"] = .bool(true)
      object["truncated"] = .bool(true)
      return true
    }
    if halveCollection(&object, key: "steps") {
      object["stepsTruncated"] = .bool(true)
      object["truncated"] = .bool(true)
      return true
    }
    return false
  }

  private func reduceDefinition(_ object: inout JSONObject) -> Bool {
    guard case var .object(definition)? = object["definition"] else {
      return false
    }
    if reduceNestedCollections(&definition, parentKey: "steps", childKeys: ["transitions"]) {
      definition["transitionsTruncated"] = .bool(true)
      object["definition"] = .object(definition)
      object["truncated"] = .bool(true)
      return true
    }
    for key in ["diagnostics", "nodes", "steps"] {
      if key == "diagnostics" {
        if halveCollection(&object, key: key) {
          object["diagnosticsTruncated"] = .bool(true)
          object["truncated"] = .bool(true)
          return true
        }
      } else if halveCollection(&definition, key: key) {
        definition["\(key)Truncated"] = .bool(true)
        object["definition"] = .object(definition)
        object["truncated"] = .bool(true)
        return true
      }
    }
    return false
  }

  private func reduceNestedCollections(
    _ object: inout JSONObject,
    parentKey: String,
    childKeys: [String]
  ) -> Bool {
    guard case let .array(parentValues)? = object[parentKey] else {
      return false
    }
    var parents = parentValues
    for childKey in childKeys {
      var changed = false
      for index in parents.indices {
        guard case var .object(parent) = parents[index],
              case let .array(values)? = parent[childKey],
              !values.isEmpty else {
          continue
        }
        parent[childKey] = .array(Array(values.suffix(values.count / 2)))
        parent["\(childKey)Truncated"] = .bool(true)
        parents[index] = .object(parent)
        changed = true
      }
      if changed {
        object[parentKey] = .array(parents)
        return true
      }
    }
    return false
  }

  private func halveCollection(_ object: inout JSONObject, key: String) -> Bool {
    guard case let .array(values)? = object[key], !values.isEmpty else {
      return false
    }
    object[key] = .array(Array(values.suffix(values.count / 2)))
    return true
  }

  private func bounded(_ value: String, limit: Int) -> WorkflowWebProjectedString {
    let truncated = value.count > limit
    return WorkflowWebProjectedString(value: String(value.prefix(limit)), truncated: truncated)
  }

  private func singleLine(_ value: String) -> String {
    value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private func containsSensitiveValue(_ value: String) -> Bool {
    let deniedPatterns = [
      #"(?i)(authorization|bearer|token|secret|password|api[_-]?key|access[_-]?key|private[ _-]?key)"#,
      #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
      #"[A-Za-z][A-Za-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@"#,
      #"(?i)\b(?:sk|pk|ghp|github_pat|xox[baprs]|AIza|AKIA)[-_]?[A-Za-z0-9_-]{8,}\b"#,
      #"\b[A-Z][A-Z0-9_]{2,}\s*="#,
      #"\b[A-Za-z0-9+/_=-]{40,}\b"#
    ]
    return deniedPatterns.contains {
      value.range(of: $0, options: .regularExpression) != nil
    }
  }

  private func synthesizedPersistedSummary(
    _ value: String,
    context: WorkflowWebPersistedSummaryContext
  ) -> String {
    let normalized = value.lowercased()
    let validationFailure = normalized.contains("validation")
      && (normalized.contains("fail") || normalized.contains("invalid"))
    let timeout = normalized.contains("timeout") || normalized.contains("timed out")
    let cancelled = normalized.contains("cancel")
    let unavailable = normalized.contains("not found") || normalized.contains("missing")

    switch context {
    case .diagnostic:
      if validationFailure { return "workflow validation failed" }
      if timeout { return "workflow operation timed out" }
      if cancelled { return "workflow operation cancelled" }
      if unavailable { return "workflow resource unavailable" }
      return "<redacted>"
    case .stepFailure:
      if validationFailure { return "step validation failed" }
      if timeout { return "step timed out" }
      if cancelled { return "step cancelled" }
      if unavailable { return "step resource unavailable" }
      return "step failed"
    case .gateFinding:
      if validationFailure { return "gate validation finding recorded" }
      return "gate finding recorded"
    case .recoveryReason:
      return "workflow recovery reason recorded"
    case .registryDiagnostic:
      if validationFailure { return "workflow validation failed" }
      if unavailable { return "workflow bundle reference unavailable" }
      return "workflow registry diagnostic recorded"
    }
  }

  private func jsonSize(_ object: JSONObject) -> Int {
    (try? JSONEncoder().encode(JSONValue.object(object)).count) ?? Int.max
  }
}
