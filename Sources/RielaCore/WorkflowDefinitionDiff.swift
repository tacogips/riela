import Foundation

public enum WorkflowDefinitionDiff {
  public static func compute(before: JSONValue, after: JSONValue) -> [WorkflowDefinitionDiffEntry] {
    var entries: [WorkflowDefinitionDiffEntry] = []
    compare(before, after, pointer: "", into: &entries)
    return entries
  }

  private static func compare(
    _ before: JSONValue,
    _ after: JSONValue,
    pointer: String,
    into entries: inout [WorkflowDefinitionDiffEntry]
  ) {
    if before == after { return }
    switch (before, after) {
    case let (.object(beforeValues), .object(afterValues)):
      let keys = Set(beforeValues.keys).union(afterValues.keys).sorted {
        Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))
      }
      for key in keys {
        let childPointer = "\(pointer)/\(escape(key))"
        switch (beforeValues[key], afterValues[key]) {
        case let (.some(oldValue), .some(newValue)):
          compare(oldValue, newValue, pointer: childPointer, into: &entries)
        case let (.none, .some(newValue)):
          entries.append(WorkflowDefinitionDiffEntry(path: childPointer, op: .add, after: newValue))
        case let (.some(oldValue), .none):
          entries.append(WorkflowDefinitionDiffEntry(path: childPointer, op: .remove, before: oldValue))
        case (.none, .none):
          break
        }
      }
    case let (.array(beforeValues), .array(afterValues)):
      let sharedCount = min(beforeValues.count, afterValues.count)
      for index in 0..<sharedCount {
        compare(beforeValues[index], afterValues[index], pointer: "\(pointer)/\(index)", into: &entries)
      }
      if beforeValues.count > sharedCount {
        for index in sharedCount..<beforeValues.count {
          entries.append(WorkflowDefinitionDiffEntry(path: "\(pointer)/\(index)", op: .remove, before: beforeValues[index]))
        }
      } else if afterValues.count > sharedCount {
        for index in sharedCount..<afterValues.count {
          entries.append(WorkflowDefinitionDiffEntry(path: "\(pointer)/\(index)", op: .add, after: afterValues[index]))
        }
      }
    default:
      entries.append(WorkflowDefinitionDiffEntry(path: pointer, op: .replace, before: before, after: after))
    }
  }

  private static func escape(_ token: String) -> String {
    token.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
  }
}
