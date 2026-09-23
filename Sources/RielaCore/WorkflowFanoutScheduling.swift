import Foundation

/// Selects one dependency-ready wave. The join step accepts results before
/// the next dispatch supplies completed branch IDs. Git branches are unrelated.
public struct WorkflowFanoutDependencies: Codable, Equatable, Sendable {
  public var branchIdFrom: String
  public var dependsOnFrom: String
  public var completedBranchIdsFrom: String?

  public init(branchIdFrom: String, dependsOnFrom: String, completedBranchIdsFrom: String? = nil) {
    self.branchIdFrom = branchIdFrom
    self.dependsOnFrom = dependsOnFrom
    self.completedBranchIdsFrom = completedBranchIdsFrom
  }
}

public struct WorkflowFanoutChangeTracking: Codable, Equatable, Sendable {
  public var pathsFrom: String
  public init(pathsFrom: String) { self.pathsFrom = pathsFrom }
}

struct WorkflowFanoutWave: Sendable {
  var selectedIndices: [Int]
  var branchIds: [String]
  var pendingBranchIds: [String]
  var completedBranchIds: [String]

  static func select(items: [JSONValue], policy: WorkflowFanoutDependencies?, source: JSONObject) throws -> Self {
    guard let policy else {
      return Self(selectedIndices: Array(items.indices), branchIds: items.indices.map(String.init),
                  pendingBranchIds: [], completedBranchIds: [])
    }
    func invalid(_ message: String) -> AdapterExecutionError {
      AdapterExecutionError(.invalidOutput, "fanout dependencies: \(message)")
    }
    func strings(_ value: JSONValue?) throws -> [String] {
      guard case let .array(values)? = value else { throw invalid("expected an array of branch IDs") }
      return try values.map {
        guard case let .string(id) = $0, !id.isEmpty else { throw invalid("invalid branch ID") }
        return id
      }
    }
    var ids: [String] = [], dependencies: [String: [String]] = [:]
    for item in items {
      guard case let .string(id)? = fanoutJSONPointer(item, policy.branchIdFrom), !id.isEmpty,
            dependencies[id] == nil else { throw invalid("missing or duplicate branch ID") }
      ids.append(id)
      dependencies[id] = try strings(fanoutJSONPointer(item, policy.dependsOnFrom))
    }
    let completed = try policy.completedBranchIdsFrom.map { try strings(fanoutJSONPointer(.object(source), $0)) } ?? []
    let completedSet = Set(completed)
    guard completedSet.count == completed.count, completedSet.isSubset(of: Set(ids)) else {
      throw invalid("unknown or duplicate completed branch IDs")
    }
    var visited = Set<String>(), visiting = Set<String>()
    func visit(_ id: String) throws {
      guard let required = dependencies[id] else { throw invalid("unknown dependency '\(id)'") }
      guard !visiting.contains(id) else { throw invalid("dependency cycle at '\(id)'") }
      if visited.contains(id) { return }
      visiting.insert(id)
      for dependency in required { try visit(dependency) }
      visiting.remove(id)
      visited.insert(id)
    }
    for id in ids { try visit(id) }
    for id in completed where !Set(dependencies[id] ?? []).isSubset(of: completedSet) {
      throw invalid("completed branch '\(id)' has an incomplete dependency")
    }
    let selected = ids.indices.filter {
      !completedSet.contains(ids[$0]) && Set(dependencies[ids[$0]] ?? []).isSubset(of: completedSet)
    }
    return Self(selectedIndices: selected, branchIds: ids,
                pendingBranchIds: ids.filter { !completedSet.contains($0) }, completedBranchIds: completed)
  }
}

func fanoutJSONPointer(_ value: JSONValue, _ pointer: String) -> JSONValue? {
  if pointer.isEmpty { return value }
  guard pointer.hasPrefix("/") else { return nil }
  var current = value
  for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
    let key = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    switch current {
    case let .object(object): guard let next = object[key] else { return nil }; current = next
    case let .array(array):
      guard let index = Int(key), array.indices.contains(index) else { return nil }; current = array[index]
    default: return nil
    }
  }
  return current
}
