#if os(macOS)
import RielaCore
import RielaKaibaSupport

/// AppKit-independent state for a single `kaiba/*` node binding selector.
public enum RielaAppKaibaBindingAvailability: Equatable, Sendable {
  case `default`
  case enabled
  case disabled
  case missing
}

/// One supported selector action. AppKit must render this projection rather
/// than deriving instance availability from raw catalog records.
public struct RielaAppKaibaNodeBindingChoice: Equatable, Sendable {
  public let instanceID: String?
  public let title: String
  public let isEnabled: Bool
  public let availability: RielaAppKaibaBindingAvailability

  public init(
    instanceID: String?,
    title: String,
    isEnabled: Bool,
    availability: RielaAppKaibaBindingAvailability
  ) {
    self.instanceID = instanceID
    self.title = title
    self.isEnabled = isEnabled
    self.availability = availability
  }
}

public struct RielaAppKaibaNodeBindingRow: Equatable, Sendable {
  public let nodeID: String
  public let effectiveInstanceID: String?
  public let usesAuthoredBinding: Bool
  public let detail: String
  public let choices: [RielaAppKaibaNodeBindingChoice]

  public init(
    nodeID: String,
    effectiveInstanceID: String?,
    usesAuthoredBinding: Bool,
    detail: String,
    choices: [RielaAppKaibaNodeBindingChoice]
  ) {
    self.nodeID = nodeID
    self.effectiveInstanceID = effectiveInstanceID
    self.usesAuthoredBinding = usesAuthoredBinding
    self.detail = detail
    self.choices = choices
  }
}

/// Resolves workflow-node bindings without exposing AppKit to the support target.
public enum RielaAppKaibaBindingController {
  public static func rows(
    workflow: WorkflowDefinition,
    preference: RielaAppDaemonWorkflowPreference,
    instances: [KaibaInstance]
  ) -> [RielaAppKaibaNodeBindingRow] {
    workflow.nodes.compactMap { node in
      guard node.addon?.name.hasPrefix("kaiba/") == true else { return nil }
      let authoredBinding = authoredBindingID(node)
      let effectiveID: String?
      if let patch = preference.nodePatches[node.id] {
        effectiveID = patch.clearsKaibaInstanceId ? nil : patch.kaibaInstanceId ?? authoredBinding
      } else {
        effectiveID = authoredBinding
      }
      let selection = selection(effectiveID: effectiveID, instances: instances)
      return RielaAppKaibaNodeBindingRow(
        nodeID: node.id,
        effectiveInstanceID: effectiveID,
        usesAuthoredBinding: authoredBinding != nil,
        detail: selection.detail,
        choices: selection.choices
      )
    }
  }

  public static func bindingRequests(
    workflow: WorkflowDefinition,
    preference: RielaAppDaemonWorkflowPreference
  ) -> [KaibaExecutionSnapshot.BindingRequest] {
    workflow.nodes.compactMap { node in
      guard let addonName = node.addon?.name, addonName.hasPrefix("kaiba/") else { return nil }
      let bindingID: String?
      if let patch = preference.nodePatches[node.id] {
        bindingID = patch.clearsKaibaInstanceId ? nil : patch.kaibaInstanceId ?? authoredBindingID(node)
      } else {
        bindingID = authoredBindingID(node)
      }
      return .init(
        instanceID: bindingID,
        requiresLongTermMemory: longTermMemoryAddonNames.contains(addonName)
      )
    }
  }

  private static func authoredBindingID(_ node: WorkflowNodeRef) -> String? {
    guard case let .string(instanceID)? = node.addon?.config?["kaibaInstanceId"] else { return nil }
    return instanceID
  }

  private static let longTermMemoryAddonNames: Set<String> = [
    "kaiba/memory-consolidate",
    "kaiba/memory-recall"
  ]

  private static func selection(
    effectiveID: String?,
    instances: [KaibaInstance]
  ) -> (detail: String, choices: [RielaAppKaibaNodeBindingChoice]) {
    var choices = [RielaAppKaibaNodeBindingChoice(
      instanceID: nil,
      title: "Default instance",
      isEnabled: true,
      availability: .default
    )]
    choices += instances.map { instance in
      RielaAppKaibaNodeBindingChoice(
        instanceID: instance.id,
        title: instance.name + (instance.isDefault ? " (Default)" : ""),
        isEnabled: instance.enabled,
        availability: instance.enabled ? .enabled : .disabled
      )
    }
    if let effectiveID {
      if let instance = instances.first(where: { $0.id == effectiveID }) {
        return (
          instance.enabled
            ? "Uses \(instance.name)."
            : "Unavailable: \(instance.name) is disabled. Select an enabled instance.",
          choices
        )
      }
      choices.append(.init(
        instanceID: effectiveID,
        title: "Missing instance: \(effectiveID)",
        isEnabled: false,
        availability: .missing
      ))
      return ("Unavailable: configured instance \(effectiveID) is missing. Select an enabled instance.", choices)
    }
    if let instance = instances.first(where: { $0.isDefault && $0.enabled }) {
      return ("Uses default instance \(instance.name).", choices)
    }
    return ("Default instance is unavailable. Select an enabled instance or configure Kaiba settings.", choices)
  }
}
#endif
