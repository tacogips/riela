import Foundation
import RielaCore

public struct WorkflowExecutionTimelineLayout: Equatable, Sendable {
  public struct Row: Equatable, Identifiable, Sendable {
    public var id: String { stepId }
    public var stepId: String
    public var nodeId: String
    public var index: Int
  }

  public struct Bar: Equatable, Identifiable, Sendable {
    public var id: String { entryId }
    public var entryId: String
    public var rowIndex: Int
    public var startFraction: Double
    public var endFraction: Double
    public var status: WorkflowStepExecutionStatus
    public var attempt: Int
  }

  public struct Connector: Equatable, Sendable {
    public var fromEntryId: String
    public var toEntryId: String
  }

  public struct AxisTick: Equatable, Sendable {
    public var fraction: Double
    public var label: String
  }

  public var rows: [Row]
  public var bars: [Bar]
  public var connectors: [Connector]
  public var timeOrigin: Date
  public var timeSpan: TimeInterval
  public var axisTicks: [AxisTick]

  public init(
    entries: [WorkflowViewerTimelineEntry],
    messages: [WorkflowViewerMessage] = [],
    workflow: WorkflowDefinition? = nil,
    now: Date
  ) {
    guard !entries.isEmpty else {
      rows = []
      bars = []
      connectors = []
      timeOrigin = now
      timeSpan = 1
      axisTicks = Self.axisTicks(span: 1)
      return
    }

    let sortedEntries = entries.sorted { lhs, rhs in
      if lhs.startedAt == rhs.startedAt {
        return lhs.executionId < rhs.executionId
      }
      return lhs.startedAt < rhs.startedAt
    }
    let stepOrder = Dictionary(uniqueKeysWithValues: (workflow?.steps ?? []).enumerated().map { ($0.element.id, $0.offset) })
    let firstStartedAtByStep = Dictionary(grouping: sortedEntries, by: \.stepId).mapValues { stepEntries in
      stepEntries.map(\.startedAt).min() ?? now
    }
    let orderedStepIds = firstStartedAtByStep.keys.sorted { lhs, rhs in
      let leftDate = firstStartedAtByStep[lhs] ?? now
      let rightDate = firstStartedAtByStep[rhs] ?? now
      if leftDate == rightDate {
        return (stepOrder[lhs] ?? Int.max, lhs) < (stepOrder[rhs] ?? Int.max, rhs)
      }
      return leftDate < rightDate
    }
    let entriesByStep = Dictionary(grouping: sortedEntries, by: \.stepId)
    rows = orderedStepIds.enumerated().map { index, stepId in
      let entry = entriesByStep[stepId]?.first
      return Row(stepId: stepId, nodeId: entry?.nodeId ?? stepId, index: index)
    }
    let rowIndexByStepId = Dictionary(uniqueKeysWithValues: rows.map { ($0.stepId, $0.index) })

    let origin = sortedEntries.map(\.startedAt).min() ?? now
    let latestEnd = sortedEntries
      .map { entry in
        entry.status == .running ? now : (entry.endedAt ?? entry.startedAt)
      }
      .max() ?? origin
    let span = max(1, latestEnd.timeIntervalSince(origin))
    timeOrigin = origin
    timeSpan = span
    bars = sortedEntries.compactMap { entry in
      guard let rowIndex = rowIndexByStepId[entry.stepId] else {
        return nil
      }
      let end = entry.status == .running ? now : (entry.endedAt ?? entry.startedAt)
      let startFraction = Self.clamp(entry.startedAt.timeIntervalSince(origin) / span)
      let endFraction = Self.clamp(max(entry.startedAt.timeIntervalSince(origin), end.timeIntervalSince(origin)) / span)
      return Bar(
        entryId: entry.executionId,
        rowIndex: rowIndex,
        startFraction: startFraction,
        endFraction: max(startFraction, endFraction),
        status: entry.status,
        attempt: entry.attempt
      )
    }
    connectors = Self.connectors(entries: sortedEntries, messages: messages)
    axisTicks = Self.axisTicks(span: span)
  }

  private static func connectors(
    entries: [WorkflowViewerTimelineEntry],
    messages: [WorkflowViewerMessage]
  ) -> [Connector] {
    var seen: Set<String> = []
    var result: [Connector] = []
    let entriesByExecutionId = Dictionary(uniqueKeysWithValues: entries.map { ($0.executionId, $0) })
    let entriesByStepId = Dictionary(grouping: entries, by: \.stepId)
      .mapValues { $0.sorted { $0.startedAt < $1.startedAt } }
    let routedMessages = messages
      .filter { $0.sourceStepExecutionId?.isEmpty == false && $0.toStepId?.isEmpty == false }
      .sorted { ($0.createdOrder ?? 0, $0.createdAt ?? .distantPast, $0.id) < ($1.createdOrder ?? 0, $1.createdAt ?? .distantPast, $1.id) }

    for message in routedMessages {
      guard let sourceExecutionId = message.sourceStepExecutionId,
        let targetStepId = message.toStepId,
        entriesByExecutionId[sourceExecutionId] != nil,
        let target = targetEntry(for: targetStepId, createdAt: message.createdAt, entriesByStepId: entriesByStepId)
      else {
        continue
      }
      appendConnector(from: sourceExecutionId, to: target.executionId, seen: &seen, result: &result)
    }
    if !result.isEmpty {
      return result
    }
    for pair in zip(entries, entries.dropFirst()) where pair.0.executionId != pair.1.executionId {
      appendConnector(from: pair.0.executionId, to: pair.1.executionId, seen: &seen, result: &result)
    }
    return result
  }

  private static func targetEntry(
    for stepId: String,
    createdAt: Date?,
    entriesByStepId: [String: [WorkflowViewerTimelineEntry]]
  ) -> WorkflowViewerTimelineEntry? {
    guard let entries = entriesByStepId[stepId] else {
      return nil
    }
    guard let createdAt else {
      return entries.first
    }
    return entries.first { $0.startedAt >= createdAt.addingTimeInterval(-0.001) } ?? entries.first
  }

  private static func appendConnector(
    from sourceExecutionId: String,
    to targetExecutionId: String,
    seen: inout Set<String>,
    result: inout [Connector]
  ) {
    let key = "\(sourceExecutionId)->\(targetExecutionId)"
    guard sourceExecutionId != targetExecutionId, seen.insert(key).inserted else {
      return
    }
    result.append(Connector(fromEntryId: sourceExecutionId, toEntryId: targetExecutionId))
  }

  private static func axisTicks(span: TimeInterval) -> [AxisTick] {
    let safeSpan = max(1, span)
    let targetTickCount = 5.0
    let rawStep = safeSpan / targetTickCount
    let magnitude = pow(10, floor(log10(rawStep)))
    let normalized = rawStep / magnitude
    let niceMultiplier: Double
    if normalized <= 1 {
      niceMultiplier = 1
    } else if normalized <= 2 {
      niceMultiplier = 2
    } else if normalized <= 5 {
      niceMultiplier = 5
    } else {
      niceMultiplier = 10
    }
    let step = max(1, niceMultiplier * magnitude)
    var ticks: [AxisTick] = []
    var value: TimeInterval = 0
    while value <= safeSpan + 0.001, ticks.count < 8 {
      ticks.append(AxisTick(fraction: clamp(value / safeSpan), label: tickLabel(seconds: value)))
      value += step
    }
    if ticks.last?.fraction != 1, ticks.count < 8 {
      ticks.append(AxisTick(fraction: 1, label: tickLabel(seconds: safeSpan)))
    }
    return ticks
  }

  private static func tickLabel(seconds: TimeInterval) -> String {
    if seconds < 60 {
      return "\(Int(round(seconds)))s"
    }
    if seconds < 3_600 {
      return "\(Int(round(seconds / 60)))m"
    }
    let hours = seconds / 3_600
    return hours < 10 ? String(format: "%.1fh", hours) : "\(Int(round(hours)))h"
  }

  private static func clamp(_ value: Double) -> Double {
    min(1, max(0, value))
  }
}
