import Foundation

/// Host-only, cross-process capacity shared by declared sandbox executions.
/// The directory comes from trusted runtime environment, never worker input.
public struct WorkflowExecutionAdmission: Codable, Equatable, Sendable {
  public var directoryEnvironment: String
  public var capacity: Int
  public var weight: Int
  public var waitTimeoutSeconds: Int

  public init(directoryEnvironment: String, capacity: Int, weight: Int = 1, waitTimeoutSeconds: Int = 600) {
    self.directoryEnvironment = directoryEnvironment
    self.capacity = capacity
    self.weight = weight
    self.waitTimeoutSeconds = waitTimeoutSeconds
  }

  private enum CodingKeys: String, CodingKey { case directoryEnvironment, capacity, weight, waitTimeoutSeconds }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    directoryEnvironment = try values.decode(String.self, forKey: .directoryEnvironment)
    capacity = try values.decode(Int.self, forKey: .capacity)
    weight = try values.decodeIfPresent(Int.self, forKey: .weight) ?? 1
    waitTimeoutSeconds = try values.decodeIfPresent(Int.self, forKey: .waitTimeoutSeconds) ?? 600
    try validate()
  }

  public func validate() throws {
    guard isValidEnvironmentVariableName(directoryEnvironment), (1...64).contains(capacity),
          (1...capacity).contains(weight), (1...3600).contains(waitTimeoutSeconds) else {
      throw AdapterExecutionError(.policyBlocked, "invalid sandbox admission policy")
    }
  }
}
