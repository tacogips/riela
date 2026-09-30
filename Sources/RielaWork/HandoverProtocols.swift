import Foundation
import RielaCore

public protocol HandoverSink: Sendable {
  var kind: HandoverSinkKind { get }
  func write(_ packet: HandoverPacket, bytes: Data, brief: String) async throws -> HandoverSinkRef
  func read(_ ref: HandoverSinkRef) async throws -> Data
}
public protocol WorkspaceHandoverRuntime: Sendable {
  func ensureBranch(root: String, attempt: AttemptID, task: TaskID, generation: Int, base: String?,
                    isolation: RepositoryIsolation, template: String) async throws -> IsolationRef
  func checkpoint(_ isolation: IsolationRef, message: String, trailer: String, paths: [String]?) async throws -> String?
  func publish(_ isolation: IsolationRef, remote: String, allowCreate: Bool, branchAllowlist: String) async throws -> PublishedBranch
  func materialize(_ deliverable: RepositoryDeliverable, into root: String, worktree: Bool, attempt: AttemptID) async throws -> IsolationRef
  func dirtyPaths(_ isolation: IsolationRef) async throws -> [String]
}
public struct PublishedBranch: Codable, Equatable, Sendable {
  public var remote: String; public var branch: String; public var sha: String; public var created: Bool
  public init(remote: String, branch: String, sha: String, created: Bool) { self.remote = remote; self.branch = branch; self.sha = sha; self.created = created }
}
public protocol DeliverablePublisher: Sendable {
  func publish(task: WorkTask, attempt: Attempt, snapshot: WorkflowRuntimePersistenceSnapshot, ownerAlive: Bool) async -> [DeliverableRef]
}
