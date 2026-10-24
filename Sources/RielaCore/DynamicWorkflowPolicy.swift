import Foundation

public struct WorkflowDynamicWorkflowTransition: Codable, Equatable, Sendable {
  public var maxIterations: Int?
  public var onFailure: WorkflowDynamicWorkflowOnFailure?
  public var limits: WorkflowDynamicWorkflowLimits?
  public var allow: WorkflowDynamicWorkflowAllow?

  public init(
    maxIterations: Int? = nil,
    onFailure: WorkflowDynamicWorkflowOnFailure? = nil,
    limits: WorkflowDynamicWorkflowLimits? = nil,
    allow: WorkflowDynamicWorkflowAllow? = nil
  ) {
    self.maxIterations = maxIterations
    self.onFailure = onFailure
    self.limits = limits
    self.allow = allow
  }
}

public enum WorkflowDynamicWorkflowOnFailure: String, Codable, Sendable {
  case `return`
  case fail
}

public struct WorkflowDynamicWorkflowLimits: Codable, Equatable, Sendable {
  public var maxDefinitionBytes: Int?
  public var maxNodes: Int?
  public var maxSteps: Int?
  public var childMaxSteps: Int?

  public init(
    maxDefinitionBytes: Int? = nil,
    maxNodes: Int? = nil,
    maxSteps: Int? = nil,
    childMaxSteps: Int? = nil
  ) {
    self.maxDefinitionBytes = maxDefinitionBytes
    self.maxNodes = maxNodes
    self.maxSteps = maxSteps
    self.childMaxSteps = childMaxSteps
  }
}

public struct WorkflowDynamicWorkflowAllow: Codable, Equatable, Sendable {
  public var nodeTypes: [String]?
  public var backends: [String]?
  public var models: [String]?
  public var addons: [String]?

  public init(
    nodeTypes: [String]? = nil,
    backends: [String]? = nil,
    models: [String]? = nil,
    addons: [String]? = nil
  ) {
    self.nodeTypes = nodeTypes
    self.backends = backends
    self.models = models
    self.addons = addons
  }
}

public struct ResolvedDynamicWorkflowBounds: Equatable, Sendable {
  public var maxIterations: Int
  public var onFailure: WorkflowDynamicWorkflowOnFailure
  public var maxDefinitionBytes: Int
  public var maxNodes: Int
  public var maxSteps: Int
  public var childMaxSteps: Int
  public var nodeTypes: Set<String>
  public var backends: Set<String>
  public var models: Set<String>
  public var addons: Set<String>

  public init(
    maxIterations: Int,
    onFailure: WorkflowDynamicWorkflowOnFailure,
    maxDefinitionBytes: Int,
    maxNodes: Int,
    maxSteps: Int,
    childMaxSteps: Int,
    nodeTypes: Set<String>,
    backends: Set<String>,
    models: Set<String>,
    addons: Set<String>
  ) {
    self.maxIterations = maxIterations
    self.onFailure = onFailure
    self.maxDefinitionBytes = maxDefinitionBytes
    self.maxNodes = maxNodes
    self.maxSteps = maxSteps
    self.childMaxSteps = childMaxSteps
    self.nodeTypes = nodeTypes
    self.backends = backends
    self.models = models
    self.addons = addons
  }
}

public enum DynamicWorkflowPolicy {
  public static let ceilings = (
    maxIterations: 16,
    maxDefinitionBytes: 262_144,
    maxNodes: 32,
    maxSteps: 64,
    childMaxSteps: 256
  )

  private static let defaultLimits = (
    maxDefinitionBytes: 65_536,
    maxNodes: 8,
    maxSteps: 16,
    childMaxSteps: 32
  )
  private static let allowedEnvelopeKeys: Set<String> = [
    "decision", "rationale", "workflow", "nodePayloads", "input"
  ]
  private static let allowedWorkflowKeys: Set<String> = [
    "workflowId", "description", "defaults", "prompts", "entryStepId", "managerStepId", "nodes", "steps"
  ]
  private static let allowedDefaultsKeys: Set<String> = ["nodeTimeoutMs", "maxLoopIterations", "fanoutConcurrency"]
  private static let allowedNodeKeys: Set<String> = ["id", "nodeFile", "kind", "execution", "repeat", "addon"]
  private static let allowedExecutionKeys: Set<String> = ["mode", "decisionBy"]
  private static let allowedStepKeys: Set<String> = [
    "id", "nodeId", "description", "role", "promptVariant", "timeoutMs", "stallTimeoutMs",
    "failurePolicy", "sessionPolicy", "transitions", "loop"
  ]
  private static let allowedLoopKeys: Set<String> = ["while", "restartAt", "maxIterations"]
  private static let allowedTransitionKeys: Set<String> = ["toStepId", "label", "fanout"]
  private static let allowedFanoutKeys: Set<String> = [
    "groupId", "itemsFrom", "itemVariable", "concurrency", "joinStepId", "failurePolicy", "resultOrder"
  ]
  private static let allowedPayloadKeys: Set<String> = [
    "id", "description", "nodeType", "executionBackend", "model", "modelFreeze", "effort",
    "systemPromptTemplate", "promptTemplate", "sessionStartPromptTemplate", "includeRuntimeVariablesInPrompt",
    "promptVariants", "sessionPolicy", "variables", "input", "output"
  ]
  private static let allowedPromptVariantKeys: Set<String> = [
    "systemPromptTemplate", "promptTemplate", "sessionStartPromptTemplate"
  ]
  private static let allowedInputKeys: Set<String> = ["description", "jsonSchema"]
  private static let allowedOutputKeys: Set<String> = ["description", "jsonSchema", "maxValidationAttempts"]

  public static func authoredDiagnostics(
    _ transition: WorkflowDynamicWorkflowTransition,
    path: String
  ) -> [WorkflowValidationDiagnostic] {
    var diagnostics: [WorkflowValidationDiagnostic] = []
    if let value = transition.maxIterations, !(1...ceilings.maxIterations).contains(value) {
      diagnostics.append(diagnostic("\(path).maxIterations", "must be between 1 and \(ceilings.maxIterations)"))
    }
    appendLimitDiagnostic(transition.limits?.maxDefinitionBytes, field: "maxDefinitionBytes", ceiling: ceilings.maxDefinitionBytes,
                          path: path, diagnostics: &diagnostics)
    appendLimitDiagnostic(transition.limits?.maxNodes, field: "maxNodes", ceiling: ceilings.maxNodes,
                          path: path, diagnostics: &diagnostics)
    appendLimitDiagnostic(transition.limits?.maxSteps, field: "maxSteps", ceiling: ceilings.maxSteps,
                          path: path, diagnostics: &diagnostics)
    appendLimitDiagnostic(transition.limits?.childMaxSteps, field: "childMaxSteps", ceiling: ceilings.childMaxSteps,
                          path: path, diagnostics: &diagnostics)

    let nodeTypes: Set<String> = ["agent", "command", "container", "sleep", "user-action", "addon"]
    for (index, nodeType) in (transition.allow?.nodeTypes ?? []).enumerated() where !nodeTypes.contains(nodeType) {
      diagnostics.append(diagnostic("\(path).allow.nodeTypes[\(index)]", "unknown node type '\(nodeType)'"))
    }
    let backends = Set(NodeExecutionBackend.allCases.map(\.rawValue))
    for (index, backend) in (transition.allow?.backends ?? []).enumerated() where !backends.contains(backend) {
      diagnostics.append(diagnostic("\(path).allow.backends[\(index)]", "unknown execution backend '\(backend)'"))
    }
    for (index, addon) in (transition.allow?.addons ?? []).enumerated() where !isValidAddonName(addon) {
      diagnostics.append(diagnostic("\(path).allow.addons[\(index)]", "must be a non-empty namespaced add-on name"))
    }
    return diagnostics
  }

  public static func resolve(
    _ transition: WorkflowDynamicWorkflowTransition,
    parentNodePayloads: [String: AgentNodePayload]
  ) -> ResolvedDynamicWorkflowBounds {
    let limits = transition.limits
    let allow = transition.allow
    return ResolvedDynamicWorkflowBounds(
      maxIterations: transition.maxIterations ?? 4,
      onFailure: transition.onFailure ?? .return,
      maxDefinitionBytes: limits?.maxDefinitionBytes ?? defaultLimits.maxDefinitionBytes,
      maxNodes: limits?.maxNodes ?? defaultLimits.maxNodes,
      maxSteps: limits?.maxSteps ?? defaultLimits.maxSteps,
      childMaxSteps: limits?.childMaxSteps ?? defaultLimits.childMaxSteps,
      nodeTypes: Set(allow?.nodeTypes ?? [NodeType.agent.rawValue]),
      backends: Set(allow?.backends ?? parentNodePayloads.values.compactMap { $0.executionBackend?.rawValue }),
      models: Set(allow?.models ?? parentNodePayloads.values.map(\.model).filter { !$0.isEmpty }),
      addons: Set(allow?.addons ?? [])
    )
  }

  public static func check(
    envelope: JSONObject,
    parentWorkflowId: String,
    bounds: ResolvedDynamicWorkflowBounds
  ) -> [WorkflowValidationDiagnostic] {
    var diagnostics: [WorkflowValidationDiagnostic] = []
    checkKeys(envelope, allowed: allowedEnvelopeKeys, path: "envelope", diagnostics: &diagnostics)

    if envelope["decision"] != .string("execute_workflow") {
      diagnostics.append(diagnostic("decision", "must be 'execute_workflow'"))
    }
    if let rationale = envelope["rationale"] {
      if case let .string(value) = rationale {
        if value.count > 2_000 {
          diagnostics.append(diagnostic("rationale", "must be at most 2000 characters"))
        }
      } else {
        diagnostics.append(diagnostic("rationale", "must be a string"))
      }
    }
    if let input = envelope["input"], case .object = input {} else if envelope["input"] != nil {
      diagnostics.append(diagnostic("input", "must be an object"))
    }

    let workflow: JSONObject
    if let value = envelope["workflow"], case let .object(object) = value {
      workflow = object
    } else {
      diagnostics.append(diagnostic("workflow", "must be an object"))
      return diagnostics
    }

    let payloads: JSONObject
    if let value = envelope["nodePayloads"] {
      if case let .object(object) = value {
        payloads = object
      } else {
        diagnostics.append(diagnostic("nodePayloads", "must be an object"))
        payloads = [:]
      }
    } else {
      payloads = [:]
    }

    if let encoded = try? JSONEncoder.sorted.encode(["workflow": JSONValue.object(workflow), "nodePayloads": .object(payloads)]) {
      if encoded.count > bounds.maxDefinitionBytes {
        diagnostics.append(diagnostic("workflow", "definition is \(encoded.count) bytes; maximum is \(bounds.maxDefinitionBytes)"))
      }
    } else {
      diagnostics.append(diagnostic("workflow", "definition could not be encoded as JSON"))
    }

    checkKeys(workflow, allowed: allowedWorkflowKeys, path: "workflow", diagnostics: &diagnostics)
    checkObjectField(workflow, key: "defaults", allowed: allowedDefaultsKeys, path: "workflow.defaults", diagnostics: &diagnostics)

    let nodes = arrayField(workflow, key: "nodes", path: "workflow.nodes", diagnostics: &diagnostics)
    let steps = arrayField(workflow, key: "steps", path: "workflow.steps", diagnostics: &diagnostics)
    if nodes.count > bounds.maxNodes {
      diagnostics.append(diagnostic("workflow.nodes", "contains \(nodes.count) nodes; maximum is \(bounds.maxNodes)"))
    }
    if steps.count > bounds.maxSteps {
      diagnostics.append(diagnostic("workflow.steps", "contains \(steps.count) steps; maximum is \(bounds.maxSteps)"))
    }

    let workflowId = workflow["workflowId"]?.stringValue
    if workflowId == nil || workflowId?.isEmpty == true {
      diagnostics.append(diagnostic("workflow.workflowId", "must be a non-empty string"))
    } else if workflowId == parentWorkflowId {
      diagnostics.append(diagnostic("workflow.workflowId", "must differ from the parent workflowId"))
    }

    for (index, node) in nodes.enumerated() {
      let path = "workflow.nodes[\(index)]"
      guard case let .object(object) = node else {
        diagnostics.append(diagnostic(path, "must be an object"))
        continue
      }
      checkKeys(object, allowed: allowedNodeKeys, path: path, diagnostics: &diagnostics)
      checkObjectField(object, key: "execution", allowed: allowedExecutionKeys, path: "\(path).execution", diagnostics: &diagnostics)
      guard let id = object["id"]?.stringValue, !id.isEmpty else {
        diagnostics.append(diagnostic("\(path).id", "must be a non-empty string"))
        continue
      }
      let payloadKey = object["nodeFile"]?.stringValue ?? id
      guard let payloadValue = payloads[payloadKey], case let .object(payload) = payloadValue else {
        diagnostics.append(diagnostic("nodePayloads.\(payloadKey)", "node '\(id)' has no payload in nodePayloads"))
        continue
      }
      let addonName = (object["addon"] as? JSONValue)?.objectValue?["name"]?.stringValue
      if object["addon"] != nil, addonName == nil {
        diagnostics.append(diagnostic("\(path).addon.name", "must be a string"))
      } else if let addonName, !bounds.addons.contains(addonName) {
        diagnostics.append(diagnostic("\(path).addon.name", "add-on '\(addonName)' is not allowed"))
      }
      validatePayload(payload, key: payloadKey, bounds: bounds, diagnostics: &diagnostics)
    }

    for (key, payloadValue) in payloads.sorted(by: { $0.key < $1.key }) {
      guard case let .object(payload) = payloadValue else {
        diagnostics.append(diagnostic("nodePayloads.\(key)", "must be an object"))
        continue
      }
      checkPayloadKeys(payload, path: "nodePayloads.\(key)", diagnostics: &diagnostics)
    }

    for (index, step) in steps.enumerated() {
      let path = "workflow.steps[\(index)]"
      guard case let .object(object) = step else {
        diagnostics.append(diagnostic(path, "must be an object"))
        continue
      }
      checkKeys(object, allowed: allowedStepKeys, path: path, diagnostics: &diagnostics)
      checkObjectField(object, key: "loop", allowed: allowedLoopKeys, path: "\(path).loop", diagnostics: &diagnostics)
      if let transitionsValue = object["transitions"] {
        guard case let .array(transitions) = transitionsValue else {
          diagnostics.append(diagnostic("\(path).transitions", "must be an array"))
          continue
        }
        for (transitionIndex, transition) in transitions.enumerated() {
          let transitionPath = "\(path).transitions[\(transitionIndex)]"
          guard case let .object(transitionObject) = transition else {
            diagnostics.append(diagnostic(transitionPath, "must be an object"))
            continue
          }
          if transitionObject["dynamicWorkflow"] != nil || transitionObject["toWorkflowId"] != nil {
            diagnostics.append(diagnostic(transitionPath, "generated workflows cannot call other workflows"))
          }
          checkKeys(transitionObject, allowed: allowedTransitionKeys, path: transitionPath, diagnostics: &diagnostics)
          checkObjectField(transitionObject, key: "fanout", allowed: allowedFanoutKeys,
                           path: "\(transitionPath).fanout", diagnostics: &diagnostics)
        }
      }
    }
    return diagnostics
  }

  private static func validatePayload(
    _ payload: JSONObject,
    key: String,
    bounds: ResolvedDynamicWorkflowBounds,
    diagnostics: inout [WorkflowValidationDiagnostic]
  ) {
    let path = "nodePayloads.\(key)"
    let nodeType: String
    if let value = payload["nodeType"] {
      guard case let .string(type) = value else {
        diagnostics.append(diagnostic("\(path).nodeType", "must be a string"))
        return
      }
      nodeType = type
    } else {
      nodeType = NodeType.agent.rawValue
    }
    if !bounds.nodeTypes.contains(nodeType) {
      diagnostics.append(diagnostic("\(path).nodeType", "node type '\(nodeType)' is not allowed"))
    }
    if nodeType == NodeType.agent.rawValue {
      guard let backend = payload["executionBackend"]?.stringValue else {
        diagnostics.append(diagnostic("\(path).executionBackend", "executionBackend is required for generated agent nodes"))
        return
      }
      if !bounds.backends.contains(backend) {
        diagnostics.append(diagnostic("\(path).executionBackend", "backend '\(backend)' is not allowed"))
      }
      guard let model = payload["model"]?.stringValue else {
        diagnostics.append(diagnostic("\(path).model", "model must be a string in the allowed model set"))
        return
      }
      if !bounds.models.contains(model) {
        diagnostics.append(diagnostic("\(path).model", "model '\(model)' is not allowed"))
      }
    }
  }

  private static func checkPayloadKeys(
    _ payload: JSONObject,
    path: String,
    diagnostics: inout [WorkflowValidationDiagnostic]
  ) {
    checkKeys(payload, allowed: allowedPayloadKeys, path: path, diagnostics: &diagnostics)
    if let variants = payload["promptVariants"] {
      guard case let .object(object) = variants else {
        diagnostics.append(diagnostic("\(path).promptVariants", "must be an object"))
        return
      }
      for (name, variant) in object.sorted(by: { $0.key < $1.key }) {
        guard case let .object(variantObject) = variant else {
          diagnostics.append(diagnostic("\(path).promptVariants.\(name)", "must be an object"))
          continue
        }
        checkKeys(variantObject, allowed: allowedPromptVariantKeys,
                  path: "\(path).promptVariants.\(name)", diagnostics: &diagnostics)
      }
    }
    checkObjectField(payload, key: "input", allowed: allowedInputKeys, path: "\(path).input", diagnostics: &diagnostics)
    checkObjectField(payload, key: "output", allowed: allowedOutputKeys, path: "\(path).output", diagnostics: &diagnostics)
  }

  private static func checkObjectField(
    _ object: JSONObject,
    key: String,
    allowed: Set<String>,
    path: String,
    diagnostics: inout [WorkflowValidationDiagnostic]
  ) {
    guard let value = object[key] else { return }
    guard case let .object(nested) = value else {
      diagnostics.append(diagnostic(path, "must be an object"))
      return
    }
    checkKeys(nested, allowed: allowed, path: path, diagnostics: &diagnostics)
  }

  private static func checkKeys(
    _ object: JSONObject,
    allowed: Set<String>,
    path: String,
    diagnostics: inout [WorkflowValidationDiagnostic]
  ) {
    for key in object.keys.sorted() where !allowed.contains(key) {
      diagnostics.append(diagnostic("\(path).\(key)", "field '\(path).\(key)' is not allowed in generated workflows"))
    }
  }

  private static func arrayField(
    _ object: JSONObject,
    key: String,
    path: String,
    diagnostics: inout [WorkflowValidationDiagnostic]
  ) -> [JSONValue] {
    guard let value = object[key] else {
      diagnostics.append(diagnostic(path, "must be an array"))
      return []
    }
    guard case let .array(array) = value else {
      diagnostics.append(diagnostic(path, "must be an array"))
      return []
    }
    return array
  }

  private static func appendLimitDiagnostic(
    _ value: Int?,
    field: String,
    ceiling: Int,
    path: String,
    diagnostics: inout [WorkflowValidationDiagnostic]
  ) {
    if let value, value <= 0 || value > ceiling {
      diagnostics.append(diagnostic("\(path).limits.\(field)", "must be between 1 and \(ceiling)"))
    }
  }

  private static func isValidAddonName(_ value: String) -> Bool {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return false }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
    return parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }
  }

  private static func diagnostic(_ path: String, _ message: String) -> WorkflowValidationDiagnostic {
    WorkflowValidationDiagnostic(
      severity: .error,
      path: path,
      message: "dynamic workflow policy: \(message)"
    )
  }
}

private extension JSONValue {
  var stringValue: String? {
    guard case let .string(value) = self else { return nil }
    return value
  }

  var objectValue: JSONObject? {
    guard case let .object(value) = self else { return nil }
    return value
  }
}

private extension JSONEncoder {
  static var sorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}
