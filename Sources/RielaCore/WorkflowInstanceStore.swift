import Foundation

public protocol WorkflowInstanceStoring: Sendable {
  func list(workflowId: String?) throws -> [WorkflowInstanceDefinition]
  func find(identity: String, workflowId: String?) throws -> WorkflowInstanceDefinition?
  func save(_ instance: WorkflowInstanceDefinition) throws
  func remove(identity: String, workflowId: String?) throws
}

public enum WorkflowInstanceStoreError: Error, Equatable, Sendable {
  case duplicateIdentity(String)
  case notFound(String)
  case ambiguousIdentity(String, [String])
  case unsupportedScope(String)
  case invalidIdentity(String)
  case io(String)
}

public struct WorkflowInstanceStoreFile: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public var version: Int
  public var instances: [WorkflowInstanceDefinition]

  public init(version: Int = Self.currentVersion, instances: [WorkflowInstanceDefinition] = []) {
    self.version = version
    self.instances = instances
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case instances
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
    if let array = try? container.decode([WorkflowInstanceDefinition].self, forKey: .instances) {
      instances = array
    } else {
      let keyed = try container.decodeIfPresent(
        [String: WorkflowInstanceDefinition].self,
        forKey: .instances
      ) ?? [:]
      instances = keyed.values.sorted { lhs, rhs in
        if lhs.workflowId == rhs.workflowId {
          return lhs.identity < rhs.identity
        }
        return lhs.workflowId < rhs.workflowId
      }
    }
  }
}
