import Foundation

public enum WorkflowDefectCode: String, Codable, Equatable, Sendable {
  case invalidCondition = "route.invalidCondition"
  case guaranteeIncomplete = "route.analysisIncomplete"
  case validationError = "workflow.validationError"
}

public enum WorkflowDefectProofStatus: String, Codable, Equatable, Sendable {
  case complete
  case incomplete
  case notApplicable
}

public enum WorkflowDefectRemediationClass: String, Codable, Equatable, Sendable {
  case correctDefinition
  case establishProducerGuarantee
}

/// A location and source-bound finding. Incomplete evidence never establishes a
/// Boolean guarantee; consumers must not interpret an empty error set as proof.
public struct WorkflowDefectDiagnostic: Codable, Equatable, Sendable {
  public var code: WorkflowDefectCode
  public var severity: WorkflowValidationSeverity
  public var proofStatus: WorkflowDefectProofStatus
  public var sourceDigest: String
  public var filePath: String
  public var pointer: String
  public var stepId: String?
  public var nodeId: String?
  public var transitionIndex: Int?
  public var witness: String?
  public var typeInformation: String?
  public var remediationClass: WorkflowDefectRemediationClass

  public init(
    code: WorkflowDefectCode,
    severity: WorkflowValidationSeverity,
    proofStatus: WorkflowDefectProofStatus,
    sourceDigest: String,
    filePath: String,
    pointer: String,
    stepId: String? = nil,
    nodeId: String? = nil,
    transitionIndex: Int? = nil,
    witness: String? = nil,
    typeInformation: String? = nil,
    remediationClass: WorkflowDefectRemediationClass
  ) {
    self.code = code
    self.severity = severity
    self.proofStatus = proofStatus
    self.sourceDigest = sourceDigest
    self.filePath = filePath
    self.pointer = pointer
    self.stepId = stepId
    self.nodeId = nodeId
    self.transitionIndex = transitionIndex
    self.witness = witness
    self.typeInformation = typeInformation
    self.remediationClass = remediationClass
  }
}

extension WorkflowDefectDiagnostic {
  private struct ResolvedLocation {
    var pointer: String
    var transitionIndex: Int?
    var stepId: String?
    var nodeId: String?
  }

  static func project(
    _ diagnostics: [WorkflowValidationDiagnostic],
    sourceDigest: String,
    stepIds: [String] = [],
    nodeIds: [String] = [],
    filePath: String = "workflow.json"
  ) -> [Self] {
    diagnostics.map { diagnostic in
      let incomplete = diagnostic.message.contains("analysis_incomplete")
      let invalidCondition = diagnostic.message.contains("route.invalidCondition")
      let code: WorkflowDefectCode = incomplete ? .guaranteeIncomplete
        : (invalidCondition ? .invalidCondition : .validationError)
      let location = pointerAndIndex(for: diagnostic.path, stepIds: stepIds, nodeIds: nodeIds)
      return Self(
        code: code,
        severity: diagnostic.severity,
        proofStatus: incomplete ? .incomplete : .complete,
        sourceDigest: sourceDigest,
        filePath: filePath,
        pointer: location.pointer,
        stepId: location.stepId,
        nodeId: location.nodeId,
        transitionIndex: location.transitionIndex,
        remediationClass: incomplete ? .establishProducerGuarantee : .correctDefinition
      )
    }.sorted {
      if $0.filePath != $1.filePath { return $0.filePath < $1.filePath }
      if $0.pointer != $1.pointer { return $0.pointer < $1.pointer }
      return $0.code.rawValue < $1.code.rawValue
    }
  }

  private static func pointerAndIndex(
    for path: String,
    stepIds: [String],
    nodeIds: [String]
  ) -> ResolvedLocation {
    var resolved = path
    var matchedStepId: String?
    var matchedNodeId: String?
    for (collection, ids) in [("steps", stepIds), ("nodes", nodeIds)] {
      if let index = ids.indices.sorted(by: { ids[$0].count > ids[$1].count }).first(where: { index in
        let prefix = "workflow.\(collection).\(ids[index])"
        return path == prefix || path.hasPrefix(prefix + ".") || path.hasPrefix(prefix + "[")
      }) {
        let prefix = "workflow.\(collection).\(ids[index])"
        resolved = "workflow.\(collection)[\(index)]" + String(path.dropFirst(prefix.count))
        if collection == "steps" { matchedStepId = ids[index] } else { matchedNodeId = ids[index] }
        break
      }
    }
    let schemaSuffix: String?
    if let boundary = resolved.range(of: ".jsonSchema/") {
      schemaSuffix = String(resolved[boundary.upperBound...])
      resolved = String(resolved[..<boundary.lowerBound]) + ".jsonSchema"
    } else {
      schemaSuffix = nil
    }
    let normalized = resolved.replacingOccurrences(of: "[", with: ".")
      .replacingOccurrences(of: "]", with: "")
    var components = normalized.split(separator: ".").map(String.init)
    if components.first == "workflow" { components.removeFirst() }
    let transitionIndex = components.firstIndex(of: "transitions").flatMap { index in
      components.indices.contains(index + 1) ? Int(components[index + 1]) : nil
    }
    var pointer = components.isEmpty ? "" : "/" + components.map {
      $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }.joined(separator: "/")
    if let schemaSuffix { pointer += "/" + schemaSuffix }
    return ResolvedLocation(
      pointer: pointer, transitionIndex: transitionIndex,
      stepId: matchedStepId, nodeId: matchedNodeId
    )
  }
}
