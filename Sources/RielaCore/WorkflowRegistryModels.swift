import Crypto
import Foundation

public enum WorkflowProvenance: String, Codable, CaseIterable, Equatable, Sendable {
  case mutable
  case immutable
}

public enum WorkflowActivationState: String, Codable, CaseIterable, Equatable, Sendable {
  case active
  case deactivated
}

public enum WorkflowRegistryScope: String, Codable, CaseIterable, Equatable, Sendable {
  case auto
  case project
  case user
  case direct
}

public enum WorkflowRegistrySourceKind: String, Codable, CaseIterable, Equatable, Sendable {
  case workflow
  case package
}

public enum WorkflowRetireMode: String, Codable, CaseIterable, Equatable, Sendable {
  case deactivate
  case delete
}

public enum WorkflowRegistryErrorCode: String, Codable, CaseIterable, Equatable, Sendable {
  case workflowNotFound = "WORKFLOW_NOT_FOUND"
  case workflowDeactivated = "WORKFLOW_DEACTIVATED"
  case immutableWorkflow = "IMMUTABLE_WORKFLOW"
  case duplicateWorkflow = "DUPLICATE_WORKFLOW"
  case invalidWorkflow = "INVALID_WORKFLOW"
  case invalidOrigin = "INVALID_ORIGIN"
  case invalidFilter = "INVALID_FILTER"
  case invalidRetireMode = "INVALID_RETIRE_MODE"
  case unsupportedBundleReference = "UNSUPPORTED_BUNDLE_REFERENCE"
  case workflowRegistryUnavailable = "WORKFLOW_REGISTRY_UNAVAILABLE"
  case unauthenticated = "UNAUTHENTICATED"
  case forbidden = "FORBIDDEN"
  case registryConflict = "REGISTRY_CONFLICT"
  case registryIOFailure = "REGISTRY_IO_FAILURE"
}

public struct WorkflowRegistryError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
  public var code: WorkflowRegistryErrorCode
  public var message: String
  public var workflowId: String?
  public var originId: String?

  public init(
    code: WorkflowRegistryErrorCode,
    message: String,
    workflowId: String? = nil,
    originId: String? = nil
  ) {
    self.code = code
    self.message = message
    self.workflowId = workflowId
    self.originId = originId
  }

  public var description: String { "\(code.rawValue): \(message)" }
}

public struct WorkflowOriginIdentity: Codable, Equatable, Hashable, Sendable {
  public var scope: WorkflowRegistryScope
  public var sourceKind: WorkflowRegistrySourceKind
  public var provenance: WorkflowProvenance
  public var name: String
  public var workflowId: String
  public var canonicalLocator: String

  public init(
    scope: WorkflowRegistryScope,
    sourceKind: WorkflowRegistrySourceKind,
    provenance: WorkflowProvenance,
    name: String,
    workflowId: String,
    canonicalLocator: String
  ) {
    self.scope = scope
    self.sourceKind = sourceKind
    self.provenance = provenance
    self.name = name
    self.workflowId = workflowId
    self.canonicalLocator = canonicalLocator
  }

  public var originId: String {
    let canonical = [
      scope.rawValue,
      sourceKind.rawValue,
      provenance.rawValue,
      name,
      workflowId,
      canonicalLocator
    ].joined(separator: "\u{1f}")
    let digest = SHA256.hash(data: Data(canonical.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return "wfo_\(digest)"
  }
}

public struct WorkflowRegistryFilter: Codable, Equatable, Sendable {
  public var query: String?
  public var description: String?
  public var scope: WorkflowRegistryScope?
  public var sourceKind: WorkflowRegistrySourceKind?
  public var provenance: WorkflowProvenance?
  public var mutable: Bool?
  public var activationState: WorkflowActivationState?

  public init(
    query: String? = nil,
    description: String? = nil,
    scope: WorkflowRegistryScope? = nil,
    sourceKind: WorkflowRegistrySourceKind? = nil,
    provenance: WorkflowProvenance? = nil,
    mutable: Bool? = nil,
    activationState: WorkflowActivationState? = nil
  ) {
    self.query = query
    self.description = description
    self.scope = scope
    self.sourceKind = sourceKind
    self.provenance = provenance
    self.mutable = mutable
    self.activationState = activationState
  }

  public func validate() throws {
    if let provenance, let mutable, (provenance == .mutable) != mutable {
      throw WorkflowRegistryError(
        code: .invalidFilter,
        message: "provenance and mutable filters disagree"
      )
    }
  }
}

public struct WorkflowRegistryTarget: Codable, Equatable, Sendable {
  public var workflowId: String
  public var scope: WorkflowRegistryScope
  public var originId: String?

  public init(workflowId: String, scope: WorkflowRegistryScope = .auto, originId: String? = nil) {
    self.workflowId = workflowId
    self.scope = scope
    self.originId = originId
  }
}
