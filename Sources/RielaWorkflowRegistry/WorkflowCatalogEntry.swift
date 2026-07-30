import Foundation
import RielaCore

public struct WorkflowCatalogEntry: Codable, Equatable, Sendable {
  public var workflowName: String
  public var workflowId: String
  public var description: String?
  public var scope: WorkflowScope
  public var sourceKind: WorkflowSourceKind
  public var provenance: WorkflowProvenance
  public var activationState: WorkflowActivationState
  public var originId: String
  public var workflowDirectory: String
  public var packageName: String?
  public var packageVersion: String?
  public var packageDirectory: String?
  public var mutable: Bool
  public var valid: Bool
  public var diagnostics: [WorkflowValidationDiagnostic]

  private enum CodingKeys: String, CodingKey {
    case workflowName
    case workflowId
    case description
    case scope
    case sourceKind
    case provenance
    case activationState
    case originId
    case workflowDirectory
    case packageName
    case packageVersion
    case packageDirectory
    case mutable
    case temporary
    case valid
    case diagnostics
  }

  public init(
    workflowName: String,
    workflowId: String? = nil,
    description: String? = nil,
    scope: WorkflowScope,
    sourceKind: WorkflowSourceKind = .workflow,
    workflowDirectory: String,
    packageName: String? = nil,
    packageVersion: String? = nil,
    packageDirectory: String? = nil,
    mutable: Bool = false,
    provenance: WorkflowProvenance? = nil,
    activationState: WorkflowActivationState = .active,
    originId: String? = nil,
    valid: Bool,
    diagnostics: [WorkflowValidationDiagnostic]
  ) {
    self.workflowName = workflowName
    self.workflowId = workflowId ?? workflowName
    self.description = description
    self.scope = scope
    self.sourceKind = sourceKind
    self.provenance = provenance ?? (mutable ? .mutable : .immutable)
    self.activationState = activationState
    self.workflowDirectory = workflowDirectory
    self.packageName = packageName
    self.packageVersion = packageVersion
    self.packageDirectory = packageDirectory
    self.mutable = self.provenance == .mutable
    self.valid = valid
    self.diagnostics = diagnostics
    self.originId = originId ?? workflowOriginIdentity(
      name: workflowName,
      workflowId: self.workflowId,
      scope: scope,
      sourceKind: sourceKind,
      provenance: self.provenance,
      locator: workflowDirectory
    ).originId
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let workflowName = try container.decode(String.self, forKey: .workflowName)
    let workflowId = try container.decodeIfPresent(String.self, forKey: .workflowId) ?? workflowName
    let scope = try container.decode(WorkflowScope.self, forKey: .scope)
    let sourceKind = try container.decode(WorkflowSourceKind.self, forKey: .sourceKind)
    let workflowDirectory = try container.decode(String.self, forKey: .workflowDirectory)
    let legacyTemporary = try container.decodeIfPresent(Bool.self, forKey: .temporary) ?? false
    let provenance = try container.decodeIfPresent(WorkflowProvenance.self, forKey: .provenance)
      ?? (legacyTemporary ? .mutable : .immutable)
    self.init(
      workflowName: workflowName,
      workflowId: workflowId,
      description: try container.decodeIfPresent(String.self, forKey: .description),
      scope: scope,
      sourceKind: sourceKind,
      workflowDirectory: workflowDirectory,
      packageName: try container.decodeIfPresent(String.self, forKey: .packageName),
      packageVersion: try container.decodeIfPresent(String.self, forKey: .packageVersion),
      packageDirectory: try container.decodeIfPresent(String.self, forKey: .packageDirectory),
      provenance: provenance,
      activationState: try container.decodeIfPresent(WorkflowActivationState.self, forKey: .activationState) ?? .active,
      originId: try container.decodeIfPresent(String.self, forKey: .originId),
      valid: try container.decode(Bool.self, forKey: .valid),
      diagnostics: try container.decode([WorkflowValidationDiagnostic].self, forKey: .diagnostics)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(workflowName, forKey: .workflowName)
    try container.encode(workflowId, forKey: .workflowId)
    try container.encodeIfPresent(description, forKey: .description)
    try container.encode(scope, forKey: .scope)
    try container.encode(sourceKind, forKey: .sourceKind)
    try container.encode(provenance, forKey: .provenance)
    try container.encode(activationState, forKey: .activationState)
    try container.encode(originId, forKey: .originId)
    try container.encode(workflowDirectory, forKey: .workflowDirectory)
    try container.encodeIfPresent(packageName, forKey: .packageName)
    try container.encodeIfPresent(packageVersion, forKey: .packageVersion)
    try container.encodeIfPresent(packageDirectory, forKey: .packageDirectory)
    try container.encode(mutable, forKey: .mutable)
    try container.encode(valid, forKey: .valid)
    try container.encode(diagnostics, forKey: .diagnostics)
  }
}
