import Foundation

/// Trusted owners reclaim their children before exiting. Waiting for that
/// owner must not release admission or replace a durable receipt prematurely.
public enum WorkflowProcessCancellation: String, Codable, Equatable, Sendable {
  case terminateGroup = "terminate-group"
  case awaitOwner = "await-owner"
}
