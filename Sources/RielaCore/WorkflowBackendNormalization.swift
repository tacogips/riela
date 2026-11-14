import Foundation

public func normalizeCliAgentBackend(_ rawValue: String) -> CliAgentBackend? {
  CliAgentBackend(rawValue: rawValue)
}

public func normalizeNodeExecutionBackend(_ rawValue: String) -> NodeExecutionBackend? {
  NodeExecutionBackend(rawValue: rawValue)
}

public func nodeExecutionBackendListText() -> String {
  let values = NodeExecutionBackend.allCases.map(\.rawValue)
  guard let last = values.last else { return "" }
  let leading = values.dropLast()
  return leading.isEmpty ? last : "\(leading.joined(separator: ", ")), or \(last)"
}
