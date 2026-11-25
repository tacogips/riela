import ACP
import AgentGateway
import RielaCore

func validateGatewayMCPServers(_ servers: [AdapterMCPServer], vendor: GatewayVendor) throws {
  guard !servers.isEmpty else { return }
  guard vendor == .codex || vendor == .claudeCode else {
    throw AdapterExecutionError(.invalidInput, "agent-gateway backend '\(vendor.rawValue)' does not support client MCP servers")
  }
  guard servers.allSatisfy({ $0.command.hasPrefix("/") }) else {
    throw AdapterExecutionError(.invalidInput, "MCP server command must be an absolute path")
  }
}

func gatewayMCPEnvironment(_ server: AdapterMCPServer) -> [ACPEnvVariable] {
  server.environment.sorted { $0.key < $1.key }.map { ACPEnvVariable(name: $0.key, value: $0.value) }
}
