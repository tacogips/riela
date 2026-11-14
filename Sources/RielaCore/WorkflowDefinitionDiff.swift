import Foundation
import RielaMemory

public enum WorkflowDefinitionDiff {
  public static func compute(before: JSONValue, after: JSONValue) -> [WorkflowDefinitionDiffEntry] {
    guard let beforeData = try? JSONCanonical.encode(before), let afterData = try? JSONCanonical.encode(after) else { return [] }
    return compute(beforeJSON: beforeData, afterJSON: afterData)
  }

  public static func compute(beforeJSON: Data, afterJSON: Data) -> [WorkflowDefinitionDiffEntry] {
    VersionedHistoryDiff.diff(before: beforeJSON, after: afterJSON).compactMap { entry in
      guard let operation = WorkflowDefinitionDiffEntry.Operation(rawValue: entry.op) else { return nil }
      return WorkflowDefinitionDiffEntry(path: entry.path, op: operation,
        before: entry.beforeJSON.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) },
        after: entry.afterJSON.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) })
    }
  }
}
