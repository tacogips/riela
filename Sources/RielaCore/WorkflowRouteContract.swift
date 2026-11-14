import Foundation

public enum WorkflowRouteControlError: Error, Equatable, Sendable, CustomStringConvertible {
  case invalidCondition(transitionIndex: Int, span: WorkflowConditionSpan)
  case missing(transitionIndex: Int, identifier: String, span: WorkflowConditionSpan)
  case wrongType(transitionIndex: Int, identifier: String, span: WorkflowConditionSpan)
  case conflictingValues(transitionIndex: Int, identifier: String, span: WorkflowConditionSpan)

  public var description: String {
    switch self {
    case let .invalidCondition(index, span):
      return "route.invalidCondition transitions[\(index)].label characters[\(span.start)..<\(span.end)]"
    case let .missing(index, identifier, span):
      return "route.missingControl transitions[\(index)].label characters[\(span.start)..<\(span.end)] \(identifier)"
    case let .wrongType(index, identifier, span):
      return "route.wrongType transitions[\(index)].label characters[\(span.start)..<\(span.end)] \(identifier)"
    case let .conflictingValues(index, identifier, span):
      return "route.conflictingValues transitions[\(index)].label characters[\(span.start)..<\(span.end)] \(identifier)"
    }
  }
}

public enum WorkflowBooleanGuarantee: Equatable, Sendable {
  case proven
  case analysisIncomplete(pointer: String, reason: String)
}

/// Absent forwarding metadata is deliberately different from a proven pass-through.
public struct WorkflowAddonOutputProvenance: Codable, Equatable, Sendable {
  public var guaranteedPayload: [String]
  public var guaranteedWhen: [String]
  public var forwardsPayload: Bool?
  public var removedPayload: [String]
  public var overwrittenPayload: [String]
  public var booleanOverwrites: [String]

  public init(
    guaranteedPayload: [String] = [],
    guaranteedWhen: [String] = [],
    forwardsPayload: Bool? = nil,
    removedPayload: [String] = [],
    overwrittenPayload: [String] = [],
    booleanOverwrites: [String] = []
  ) {
    self.guaranteedPayload = guaranteedPayload
    self.guaranteedWhen = guaranteedWhen
    self.forwardsPayload = forwardsPayload
    self.removedPayload = removedPayload
    self.overwrittenPayload = overwrittenPayload
    self.booleanOverwrites = booleanOverwrites
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case guaranteedPayload
    case guaranteedWhen
    case forwardsPayload
    case removedPayload
    case overwrittenPayload
    case booleanOverwrites
  }

  private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }

  public init(from decoder: Decoder) throws {
    let raw = try decoder.container(keyedBy: AnyKey.self)
    let allowed = Set(CodingKeys.allCases.map(\.rawValue))
    if let unsupported = raw.allKeys.map(\.stringValue).sorted().first(where: { !allowed.contains($0) }) {
      throw DecodingError.dataCorrupted(.init(
        codingPath: decoder.codingPath,
        debugDescription: "unsupported output provenance key '\(unsupported)'"
      ))
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guaranteedPayload = try container.decodeIfPresent([String].self, forKey: .guaranteedPayload) ?? []
    guaranteedWhen = try container.decodeIfPresent([String].self, forKey: .guaranteedWhen) ?? []
    forwardsPayload = try container.decodeIfPresent(Bool.self, forKey: .forwardsPayload)
    removedPayload = try container.decodeIfPresent([String].self, forKey: .removedPayload) ?? []
    overwrittenPayload = try container.decodeIfPresent([String].self, forKey: .overwrittenPayload) ?? []
    booleanOverwrites = try container.decodeIfPresent([String].self, forKey: .booleanOverwrites) ?? []
  }
}

public struct WorkflowAddonRouteEvidence: Equatable, Sendable {
  public var name: String
  public var version: String
  public var contentDigest: String?
  public var output: WorkflowAddonOutputProvenance

  public init(name: String, version: String, contentDigest: String? = nil, output: WorkflowAddonOutputProvenance) {
    self.name = name
    self.version = version
    self.contentDigest = contentDigest
    self.output = output
  }
}

public struct WorkflowRouteContract: Sendable {
  public init() {}

  public func provePayloadBoolean(identifier: String, schema: JSONObject) -> WorkflowBooleanGuarantee {
    var remaining = 4_096
    return proveObjectBoolean(identifier: identifier, schema: schema, pointer: "", remaining: &remaining)
  }

  private func proveObjectBoolean(
    identifier: String,
    schema: JSONObject,
    pointer: String,
    remaining: inout Int
  ) -> WorkflowBooleanGuarantee {
    guard remaining > 0 else { return .analysisIncomplete(pointer: pointer, reason: "4096-node budget exhausted") }
    remaining -= 1
    if let constant = schema["const"], case let .object(object) = constant {
      return object[identifier].map(isBoolean) == true
        ? .proven : .analysisIncomplete(pointer: pointer + "/const", reason: "control is absent or non-Boolean")
    }
    if case let .array(values)? = schema["enum"], !values.isEmpty {
      guard values.count <= remaining else {
        return .analysisIncomplete(pointer: pointer + "/enum", reason: "4096-node budget exhausted")
      }
      remaining -= values.count
      return values.allSatisfy { value in
        guard case let .object(object) = value else { return false }
        return object[identifier].map(isBoolean) == true
      } ? .proven : .analysisIncomplete(pointer: pointer + "/enum", reason: "an alternative lacks a Boolean control")
    }

    let escaped = identifier.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    let propertyPointer = pointer + "/properties/" + escaped
    if case let .array(required)? = schema["required"],
       required.contains(.string(identifier)),
       case let .object(properties)? = schema["properties"],
       case let .object(property)? = properties[identifier],
       proveBooleanValue(property, pointer: propertyPointer, remaining: &remaining) == .proven {
      return .proven
    }

    for key in ["anyOf", "oneOf"] {
      if case let .array(alternatives)? = schema[key], !alternatives.isEmpty {
        for (index, alternative) in alternatives.enumerated() {
          guard case let .object(branch) = alternative else {
            return .analysisIncomplete(pointer: pointer + "/\(key)/\(index)", reason: "unsupported alternative")
          }
          let proof = proveObjectBoolean(
            identifier: identifier, schema: branch, pointer: pointer + "/\(key)/\(index)", remaining: &remaining
          )
          guard proof == .proven else { return proof }
        }
        return .proven
      }
    }

    if case let .array(parts)? = schema["allOf"], !parts.isEmpty {
      guard parts.count <= remaining else {
        return .analysisIncomplete(pointer: pointer + "/allOf", reason: "4096-node budget exhausted")
      }
      remaining -= parts.count
      var mergedRequired: [JSONValue] = []
      var mergedProperties: JSONObject = [:]
      for (index, part) in parts.enumerated() {
        guard case let .object(object) = part,
              object["anyOf"] == nil, object["oneOf"] == nil, object["allOf"] == nil else {
          return .analysisIncomplete(pointer: pointer + "/allOf/\(index)", reason: "unsupported intersection")
        }
        if case let .array(required)? = object["required"] { mergedRequired += required }
        if case let .object(properties)? = object["properties"] {
          for (key, value) in properties {
            if let previous = mergedProperties[key], previous != value {
              return .analysisIncomplete(pointer: pointer + "/allOf/\(index)/properties", reason: "unproven property intersection")
            }
            mergedProperties[key] = value
          }
        }
      }
      return proveObjectBoolean(
        identifier: identifier,
        schema: ["required": .array(mergedRequired), "properties": .object(mergedProperties)],
        pointer: pointer + "/allOf", remaining: &remaining
      )
    }
    return .analysisIncomplete(pointer: propertyPointer, reason: "required Boolean payload control is unproven")
  }

  private func proveBooleanValue(
    _ schema: JSONObject,
    pointer: String,
    remaining: inout Int
  ) -> WorkflowBooleanGuarantee {
    guard remaining > 0 else { return .analysisIncomplete(pointer: pointer, reason: "4096-node budget exhausted") }
    remaining -= 1
    if let constant = schema["const"], isBoolean(constant) { return .proven }
    if case let .array(values)? = schema["enum"], !values.isEmpty {
      guard values.count <= remaining else {
        return .analysisIncomplete(pointer: pointer + "/enum", reason: "4096-node budget exhausted")
      }
      remaining -= values.count
      if values.allSatisfy(isBoolean) { return .proven }
    }
    return schema["type"] == .string("boolean")
      ? .proven : .analysisIncomplete(pointer: pointer, reason: "Boolean value is unproven")
  }

  private func isBoolean(_ value: JSONValue) -> Bool {
    if case .bool = value { return true }
    return false
  }

  /// Inspects producer-owned values before carried fields or routing policy can
  /// change the candidate. Every referenced control is checked, regardless of
  /// Boolean short-circuiting or transition selection order.
  public func validateCandidate(
    _ candidate: RuntimeOutputCandidate,
    transitions: [WorkflowStepTransition]
  ) throws {
    for (index, transition) in transitions.enumerated() {
      guard let label = transition.label else { continue }
      let condition: ParsedWorkflowCondition
      do {
        condition = try ParsedWorkflowCondition(label)
      } catch let WorkflowConditionError.syntax(span) {
        throw WorkflowRouteControlError.invalidCondition(transitionIndex: index, span: span)
      }
      for use in condition.identifiers {
        let whenValue = candidate.when[use.name]
        let payloadValue = candidate.payload[use.name]
        if let payloadValue, case .bool = payloadValue {} else if payloadValue != nil {
          throw WorkflowRouteControlError.wrongType(
            transitionIndex: index, identifier: use.name, span: use.span
          )
        }
        if let whenValue, case let .bool(payloadBoolean)? = payloadValue, whenValue != payloadBoolean {
          throw WorkflowRouteControlError.conflictingValues(
            transitionIndex: index, identifier: use.name, span: use.span
          )
        }
        if whenValue == nil && payloadValue == nil {
          throw WorkflowRouteControlError.missing(
            transitionIndex: index, identifier: use.name, span: use.span
          )
        }
      }
    }
  }

  public func validateCarriedFields(
    _ carried: JSONObject,
    candidate: RuntimeOutputCandidate,
    transitions: [WorkflowStepTransition]
  ) throws {
    guard !carried.isEmpty else { return }
    for (index, transition) in transitions.enumerated() {
      guard let label = transition.label else { continue }
      let condition: ParsedWorkflowCondition
      do {
        condition = try ParsedWorkflowCondition(label)
      } catch let WorkflowConditionError.syntax(span) {
        throw WorkflowRouteControlError.invalidCondition(transitionIndex: index, span: span)
      }
      for use in condition.identifiers {
        if let carriedValue = carried[use.name], carriedValue != candidate.payload[use.name] {
          throw WorkflowRouteControlError.conflictingValues(
            transitionIndex: index, identifier: use.name, span: use.span
          )
        }
      }
    }
  }
}
