import Foundation
import RielaCore

public protocol WorkflowInjectedInterruption: Error {}

public struct WorkflowTransactionStableMetadata: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var transactionId: String
  public var target: WorkflowBundleIdentity
  public var historyRoot: String
  public var physicalOwnershipRoot: String?
  public var physicalOwnershipContainerDevice: UInt64?
  public var physicalOwnershipContainerInode: UInt64?

  public init(
    schemaVersion: Int = 1,
    transactionId: String,
    target: WorkflowBundleIdentity,
    historyRoot: String,
    physicalOwnershipRoot: String? = nil,
    physicalOwnershipContainerDevice: UInt64? = nil,
    physicalOwnershipContainerInode: UInt64? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.transactionId = transactionId
    self.target = target
    self.historyRoot = historyRoot
    self.physicalOwnershipRoot = physicalOwnershipRoot
    self.physicalOwnershipContainerDevice = physicalOwnershipContainerDevice
    self.physicalOwnershipContainerInode = physicalOwnershipContainerInode
  }

  public static func url(forOwnershipRoot root: URL) -> URL {
    root.deletingLastPathComponent().appendingPathComponent(
      ".\(root.lastPathComponent).riela-active-transaction.json"
    )
  }
}
