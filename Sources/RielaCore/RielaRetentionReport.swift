import Foundation

public struct RetentionPolicySnapshot: Codable, Equatable, Sendable {
  public var maxAgeDays: Int?
  public var maxTotalBytes: Int64?

  public init(maxAgeDays: Int?, maxTotalBytes: Int64?) {
    self.maxAgeDays = maxAgeDays
    self.maxTotalBytes = maxTotalBytes
  }
}

public struct RetentionProtectedFamily: Codable, Equatable, Sendable {
  public var rootId: String
  public var reason: String

  public init(rootId: String, reason: String) {
    self.rootId = rootId
    self.reason = reason
  }
}

public struct RetentionCategoryReport: Codable, Equatable, Sendable {
  public var state: RielaRetentionCategoryState
  public var policy: RetentionPolicySnapshot?
  public var selectedCount: Int
  public var removedCount: Int
  public var selectedBytes: Int64
  public var removedBytes: Int64
  public var beforeBytes: Int64
  public var remainingBytes: Int64
  public var capAchieved: Bool?
  public var protected: [String: Int]
  public var protectedFamilies: [RetentionProtectedFamily]
  public var pendingCleanupCount: Int
  public var workLimitReached: Bool
  public var orphanSessionCount: Int

  public init(
    state: RielaRetentionCategoryState,
    policy: RetentionPolicySnapshot?,
    selectedCount: Int,
    removedCount: Int,
    selectedBytes: Int64,
    removedBytes: Int64,
    beforeBytes: Int64,
    remainingBytes: Int64,
    capAchieved: Bool?,
    protected: [String: Int],
    protectedFamilies: [RetentionProtectedFamily],
    pendingCleanupCount: Int,
    workLimitReached: Bool,
    orphanSessionCount: Int
  ) {
    self.state = state
    self.policy = policy
    self.selectedCount = selectedCount
    self.removedCount = removedCount
    self.selectedBytes = selectedBytes
    self.removedBytes = removedBytes
    self.beforeBytes = beforeBytes
    self.remainingBytes = remainingBytes
    self.capAchieved = capAchieved
    self.protected = protected
    self.protectedFamilies = protectedFamilies
    self.pendingCleanupCount = pendingCleanupCount
    self.workLimitReached = workLimitReached
    self.orphanSessionCount = orphanSessionCount
  }

  public static func inactive(_ state: RielaRetentionCategoryState) -> RetentionCategoryReport {
    RetentionCategoryReport(
      state: state,
      policy: nil,
      selectedCount: 0,
      removedCount: 0,
      selectedBytes: 0,
      removedBytes: 0,
      beforeBytes: 0,
      remainingBytes: 0,
      capAchieved: nil,
      protected: [:],
      protectedFamilies: [],
      pendingCleanupCount: 0,
      workLimitReached: false,
      orphanSessionCount: 0
    )
  }
}
