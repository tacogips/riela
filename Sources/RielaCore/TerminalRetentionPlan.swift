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
  public var messageBytes: Int64
  public var protection: String?

  public init(id: String, workflowId: String, parentId: String? = nil, rootId: String? = nil,
              statuses: Set<String>, updatedAt: Date?, payloadBytes: Int64, messageBytes: Int64 = 0,
              protection: String? = nil) {
    self.id = id; self.workflowId = workflowId; self.parentId = parentId; self.rootId = rootId ?? id
    self.statuses = statuses; self.updatedAt = updatedAt; self.payloadBytes = payloadBytes
    self.messageBytes = messageBytes; self.protection = protection
  }
}

public enum TerminalRetentionScope: Equatable, Sendable {
  case workflows(Set<String>)
  case allExcept(Set<String>)
}

public enum TerminalRetentionByteKind: Equatable, Sendable {
  case results
  case messages
}

public struct TerminalRetentionFamily: Equatable, Sendable {
  public var ids: [String]
  public var rootId: String
  public var updatedAt: Date
  public var payloadBytes: Int64
  public var messageBytes: Int64
  public var protection: String?
}

public struct TerminalRetentionPlan: Equatable, Sendable {
  public var selected: [TerminalRetentionFamily]
  public var protected: [TerminalRetentionFamily]
  public var eligible: [TerminalRetentionFamily]
  public var beforeBytes: Int64
  public var projectedRemainingBytes: Int64
  public var capAchieved: Bool
  public var workLimitReached: Bool

  /// Plan from a consistent metadata snapshot. The executor must lock and recheck
  /// each entire family before acting; this value alone never authorizes deletion.
  public static func make(sessions: [TerminalRetentionSession], workflows: Set<String>,
                          now: Date, retentionHours: Int, maxPayloadBytes: Int64) throws -> Self {
    guard !workflows.isEmpty, workflows.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512 }),
          (1...8760).contains(retentionHours),
          (1...68_719_476_736).contains(maxPayloadBytes),
          Set(sessions.map(\.id)).count == sessions.count,
          sessions.allSatisfy({ $0.payloadBytes >= 0 && $0.messageBytes >= 0 }) else {
      throw TerminalRetentionPlanError.invalidPolicyOrMetadata
    }
    // The existing session-prune cap includes both result and message copies.
    // Independent category policies use the original split byte counters.
    var combined = sessions
    for index in combined.indices {
      let total = combined[index].payloadBytes.addingReportingOverflow(combined[index].messageBytes)
      guard !total.overflow else { throw TerminalRetentionPlanError.invalidPolicyOrMetadata }
      combined[index].payloadBytes = total.partialValue
      combined[index].messageBytes = 0
    }
    return try make(sessions: combined, scope: .workflows(workflows), now: now,
      maxAge: Double(retentionHours) * 3600, maxBytes: maxPayloadBytes, bytes: .results)
  }

  public static func make(sessions: [TerminalRetentionSession], scope: TerminalRetentionScope, now: Date,
                          maxAge: TimeInterval?, maxBytes: Int64?, bytes: TerminalRetentionByteKind,
                          familyLimit: Int = .max) throws -> Self {
    let validIDs: (Set<String>) -> Bool = { values in
      values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512 }
    }
    let validScope: Bool
    switch scope {
    case .workflows(let values): validScope = !values.isEmpty && validIDs(values)
    case .allExcept(let values): validScope = validIDs(values)
    }
    guard validScope, (maxAge.map { $0 > 0 && $0 <= 36_500 * 86_400 } ?? false) || maxBytes != nil,
          maxAge.map({ $0 > 0 && $0 <= 36_500 * 86_400 }) ?? true,
          maxBytes.map({ $0 >= 1 && $0 <= (1 << 50) }) ?? true,
          familyLimit >= 1, Set(sessions.map(\.id)).count == sessions.count,
          sessions.allSatisfy({ $0.payloadBytes >= 0 && $0.messageBytes >= 0 }) else {
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
      let inScope: Bool
      switch scope {
      case .workflows(let workflows): inScope = members.contains(where: { workflows.contains($0.workflowId) })
      case .allExcept: inScope = true
      }
      guard inScope else { continue }
      var reason: String?
      if case .allExcept(let keep) = scope, members.contains(where: { keep.contains($0.workflowId) }) {
        reason = "keptWorkflow"
      }
      if roots.count != 1 || members.contains(where: {
        ($0.parentId.map { !ids.contains($0) } ?? false) || !ids.contains($0.rootId)
      }) { reason = "unresolvedLineage" }
      if case .workflows(let workflows) = scope, roots.count == 1,
         !workflows.contains(roots[0].workflowId) { reason = "rootOutsideScope" }
      if members.contains(where: { $0.statuses.count != 1 || !$0.statuses.isSubset(of: ["completed", "failed", "cancelled"]) }) {
        reason = "nonterminalOrConflictingStatus"
      }
      if members.contains(where: { $0.updatedAt == nil || ($0.updatedAt ?? now) > now }) { reason = "unknownOrFutureTimestamp" }
      if let explicit = members.compactMap(\.protection).sorted().first { reason = explicit }
      var payloadBytes: Int64 = 0, messageBytes: Int64 = 0
      for member in members {
        let payloadSum = payloadBytes.addingReportingOverflow(member.payloadBytes)
        let messageSum = messageBytes.addingReportingOverflow(member.messageBytes)
        guard !payloadSum.overflow, !messageSum.overflow else {
          throw TerminalRetentionPlanError.invalidPolicyOrMetadata
        }
        payloadBytes = payloadSum.partialValue; messageBytes = messageSum.partialValue
      }
      families.append(.init(ids: ids.sorted(), rootId: roots.first?.id ?? ids.sorted()[0],
        updatedAt: members.compactMap(\.updatedAt).max() ?? now, payloadBytes: payloadBytes,
        messageBytes: messageBytes, protection: reason))
    }
    let ordered = families.sorted(by: {
      $0.updatedAt == $1.updatedAt ? $0.rootId < $1.rootId : $0.updatedAt < $1.updatedAt
    })
    let eligible = ordered.filter { family in
      family.protection == nil && (bytes != .messages || family.messageBytes > 0)
    }
    var before: Int64 = 0
    for family in families {
      let amount = bytes == .results ? family.payloadBytes : family.messageBytes
      let sum = before.addingReportingOverflow(amount)
      guard !sum.overflow else { throw TerminalRetentionPlanError.invalidPolicyOrMetadata }
      before = sum.partialValue
    }
    var remaining = before, selected: [TerminalRetentionFamily] = [], workLimitReached = false
    let cutoff = maxAge.map { now.addingTimeInterval(-$0) }
    for family in eligible {
      let shouldSelect = (cutoff.map { family.updatedAt <= $0 } ?? false) ||
        (maxBytes.map { remaining > $0 } ?? false)
      guard shouldSelect else { continue }
      guard selected.count < familyLimit else { workLimitReached = true; break }
      selected.append(family)
      remaining -= bytes == .results ? family.payloadBytes : family.messageBytes
    }
    return .init(selected: selected, protected: families.filter { $0.protection != nil }, eligible: eligible,
      beforeBytes: before, projectedRemainingBytes: remaining,
      capAchieved: maxBytes.map { remaining <= $0 } ?? true, workLimitReached: workLimitReached)
  }
}

public enum TerminalRetentionPlanError: Error, Equatable, Sendable {
  case invalidPolicyOrMetadata
}
