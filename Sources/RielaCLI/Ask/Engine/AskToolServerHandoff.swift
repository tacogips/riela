import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum AskToolTransportSelection {
  static func select(
    backend: NodeExecutionBackend, rielaExecutablePath: String?, environment: [String: String]
  ) -> AskToolTransport {
    guard backend == .codexAgent || backend == .claudeCodeAgent,
          rielaExecutablePath?.hasPrefix("/") == true,
          environment["RIELA_ASK_TOOL_TRANSPORT"] != "rounds",
          environment[AskScriptedBackend.environmentKey] == nil else { return .rounds }
    return .mcp
  }
}

enum AskToolServerHandoff {
  static let serverName = "riela-ask"

  static func environment(from host: [String: String]) -> [String: String] {
    let secrets = BotMemoryRuntime.redactionRules(environment: host).boundValues.keys
    return host.filter { key, value in
      (key == "HOME" || key.hasPrefix("RIELA_") || key.hasPrefix("XDG_"))
        && key != AskScriptedBackend.environmentKey && key != "RIELA_ASK_TOOL_TRANSPORT"
        && !BotMemoryRuntime.isSecretName(key) && !secrets.contains(where: { value.range(of: $0) != nil })
    }
  }

  static func redactionFile(for turnDirectory: URL) -> URL {
    turnDirectory.deletingLastPathComponent().appendingPathComponent("redaction", isDirectory: true)
      .appendingPathComponent(turnDirectory.lastPathComponent).appendingPathExtension("json")
  }

  static func makeServer(host: AskHost, conversationId: String, turnId: String, valuesFile: URL) throws -> AdapterMCPServer {
    guard let command = host.rielaExecutablePath else {
      throw AdapterExecutionError(.invalidInput, "Missing Ask tool-server executable")
    }
    // The tool-server CLI takes the session-store directory containing runtime-records.
    let root = URL(fileURLWithPath: host.sessionStoreRoot, isDirectory: true).deletingLastPathComponent().path
    var arguments = [
      "ask", "tool-server", "--session-store", root, "--working-dir", host.workingDirectory,
      "--conversation", conversationId, "--turn", turnId, "--redaction-values", valuesFile.path
    ]
    if let scope = host.scope {
      arguments.append(contentsOf: ["--scope", scope.rawValue])
    }
    return AdapterMCPServer(
      name: serverName, command: command, arguments: arguments, environment: environment(from: host.environment)
    )
  }

  static func writeRedactionValues(environment: [String: String], to file: URL) throws {
    let unavailable = AskError(code: "redaction_values_unavailable", message: "Ask tool-server redaction values are unavailable")
    do {
      let directory = file.deletingLastPathComponent()
      guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else { throw unavailable }
      let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard parent >= 0 else { throw unavailable }
      defer { _ = close(parent) }
      var directoryInfo = stat()
      guard fstat(parent, &directoryInfo) == 0, directoryInfo.st_mode & 0o777 == 0o700 else { throw unavailable }

      let values = BotMemoryRuntime.redactionRules(environment: environment).boundValues
      let data = try JSONEncoder().encode(values)
      let descriptor = openat(parent, file.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else { throw unavailable }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      do {
        guard fchmod(descriptor, 0o600) == 0 else { throw unavailable }
        try handle.write(contentsOf: data)
        try handle.close()
      } catch {
        _ = unlinkat(parent, file.lastPathComponent, 0)
        throw error
      }
    } catch {
      throw unavailable
    }
  }
}
