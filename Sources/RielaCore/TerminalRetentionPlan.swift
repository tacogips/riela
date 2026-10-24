import Foundation

/// Metadata-only input. Payloads are never loaded to decide retention eligibility.
public struct TerminalRetentionSession: Equatable, Sendable {
  public var id: String
  public var workflowId: String
  public var parentId: String?
  public var rootId: String
  public var statuses: Set<String>
  public var updatedAt: Date?
  public var payloadBytes: Int64
  public var protection: String?

  public init(id: String, workflowId: String, parentId: String? = nil, rootId: String? = nil,
              statuses: Set<String>, updatedAt: Date?, payloadBytes: Int64, protection: String? = nil) {
    self.id = id; self.workflowId = workflowId; self.parentId = parentId; self.rootId = rootId ?? id
    self.statuses = statuses; self.updatedAt = updatedAt; self.payloadBytes = payloadBytes; self.protection = protection
  }
}

public struct TerminalRetentionFamily: Equatable, Sendable {
  public var ids: [String]
  public var rootId: String
  public var updatedAt: Date
  public var payloadBytes: Int64
  public var protection: String?
}

public struct TerminalRetentionPlan: Equatable, Sendable {
  public var selected: [TerminalRetentionFamily]
  public var protected: [TerminalRetentionFamily]
  public var beforeBytes: Int64
  public var projectedRemainingBytes: Int64
  public var capAchieved: Bool

  /// Plan from a consistent metadata snapshot. The executor must lock and recheck
  /// each entire family before acting; this value alone never authorizes deletion.
  public static func make(sessions: [TerminalRetentionSession], workflows: Set<String>,
                          now: Date, retentionHours: Int, maxPayloadBytes: Int64) throws -> Self {
    guard !workflows.isEmpty, workflows.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512 }),
          (1...8760).contains(retentionHours),
          (1...68_719_476_736).contains(maxPayloadBytes),
          Set(sessions.map(\.id)).count == sessions.count,
          sessions.allSatisfy({ $0.payloadBytes >= 0 }) else {
      throw TerminalRetentionPlanError.invalidPolicyOrMetadata
    }
    let rows = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    var adjacency: [String: Set<String>] = [:]
    for row in sessions {
      adjacency[row.id, default: []].insert(row.id)
      for related in [row.parentId, Optional(row.rootId)].compactMap({ $0 }) where rows[related] != nil {
        adjacency[row.id, default: []].insert(related)
        adjacency[related, default: []].insert(row.id)
      }
    }
    var visited: Set<String> = [], families: [TerminalRetentionFamily] = []
    for row in sessions.sorted(by: { $0.id < $1.id }) where !visited.contains(row.id) {
      var pending = [row.id], ids: Set<String> = []
      while let id = pending.popLast() {
        guard ids.insert(id).inserted else { continue }
        pending.append(contentsOf: adjacency[id, default: []].subtracting(ids))
      }
      visited.formUnion(ids)
      let members = ids.compactMap { rows[$0] }
      let roots = members.filter { $0.parentId == nil && $0.rootId == $0.id }
      guard members.contains(where: { workflows.contains($0.workflowId) }) else { continue }
      var reason: String?
      if roots.count != 1 || members.contains(where: {
        ($0.parentId.map { !ids.contains($0) } ?? false) || !ids.contains($0.rootId)
      }) { reason = "unresolvedLineage" }
      if roots.count == 1, !workflows.contains(roots[0].workflowId) { reason = "rootOutsideScope" }
      if members.contains(where: { $0.statuses.count != 1 || !$0.statuses.isSubset(of: ["completed", "failed", "cancelled"]) }) {
        reason = "nonterminalOrConflictingStatus"
      }
      if members.contains(where: { $0.updatedAt == nil || ($0.updatedAt ?? now) > now }) { reason = "unknownOrFutureTimestamp" }
      if let explicit = members.compactMap(\.protection).sorted().first { reason = explicit }
      var bytes: Int64 = 0
      for member in members {
        let sum = bytes.addingReportingOverflow(member.payloadBytes)
        guard !sum.overflow else { throw TerminalRetentionPlanError.invalidPolicyOrMetadata }
        bytes = sum.partialValue
      }
      families.append(.init(ids: ids.sorted(), rootId: roots.first?.id ?? ids.sorted()[0],
        updatedAt: members.compactMap(\.updatedAt).max() ?? now, payloadBytes: bytes, protection: reason))
    }
    var before: Int64 = 0
    for family in families {
      let sum = before.addingReportingOverflow(family.payloadBytes)
      guard !sum.overflow else { throw TerminalRetentionPlanError.invalidPolicyOrMetadata }
      before = sum.partialValue
    }
    var remaining = before, selected: [TerminalRetentionFamily] = []
    let cutoff = now.addingTimeInterval(-Double(retentionHours) * 3600)
    for family in families.filter({ $0.protection == nil }).sorted(by: {
      $0.updatedAt == $1.updatedAt ? $0.rootId < $1.rootId : $0.updatedAt < $1.updatedAt
    }) where family.updatedAt <= cutoff || remaining > maxPayloadBytes {
      selected.append(family)
      remaining -= family.payloadBytes
    }
    return .init(selected: selected, protected: families.filter { $0.protection != nil },
      beforeBytes: before, projectedRemainingBytes: remaining, capAchieved: remaining <= maxPayloadBytes)
  }
}

public enum TerminalRetentionPlanError: Error, Equatable, Sendable {
  case invalidPolicyOrMetadata
}
