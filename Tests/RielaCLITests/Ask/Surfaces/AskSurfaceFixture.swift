import Foundation
import RielaCore
import RielaGraphQL
import Testing
@testable import RielaCLI

final class AskSurfaceFixture: Sendable {
  private static let repository = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in
    url.deletingLastPathComponent()
  }

  let root: URL
  var sessionRoot: String { path("sessions") }
  var environment: [String: String] {
    [
      "HOME": path("home"), "XDG_STATE_HOME": path("state"), "XDG_CONFIG_HOME": path("config"),
      "XDG_CACHE_HOME": path("cache"), "RIELA_WORKFLOW_HOME": path("workflows"),
      "RIELA_CREDENTIAL_DIR": path("credentials"), "RIELA_MEMORY_ROOT": path("memory"),
      "RIELA_ASK_SCRIPTED_BACKEND": path("script.json"), "PATH": path("no-vendors")
    ]
  }
  var store: BotStore { BotStore(sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionRoot)) }
  var examples: URL { Self.repository.appendingPathComponent("examples") }
  var registry: RemoteRegistry { RemoteRegistry(environment: environment) }

  init() throws {
    root = Self.repository.appendingPathComponent("tmp/ask-riela/ask-04-surfaces/fixture-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  func path(_ name: String) -> String { root.appendingPathComponent(name).path }

  func script(_ rounds: [String]) throws {
    let data = try JSONEncoder().encode(["rounds": rounds])
    try data.write(to: URL(fileURLWithPath: path("script.json")))
  }

  func run(_ args: [String], transport: @escaping RemoteHTTP.Transport = RemoteHTTP.production) async -> CLICommandResult {
    let runner = ScopedParityCommandRunner(remoteTransport: transport)
    return await RielaCLIApplication(scopedCommandRunner: runner).run(args, environment: environment)
  }

  func ask(_ args: [String], transport: @escaping RemoteHTTP.Transport = RemoteHTTP.production) async -> CLICommandResult {
    // Store options go before the message so a literal after "--" remains untouched.
    await run(["ask", "--working-dir", root.path, "--session-store", sessionRoot] + args, transport: transport)
  }

  func decode<Value: Decodable>(_ type: Value.Type, _ result: CLICommandResult) throws -> Value {
    try #require(result.exitCode == .success, Comment(rawValue: result.stderr))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(result.stdout.utf8))
  }

  func seedBot(_ id: String = "fixture-bot") throws {
    let now = RoutineStore.timestamp(Date())
    _ = try store.create(BotRecord(botId: id, name: id, createdAt: now, updatedAt: now))
  }

  static let pauseProposal = """
  {"type":"tool","name":"propose_action","arguments":{"kind":"setBotPaused","target":{"botId":"fixture-bot","paused":true},"reason":"Pause requested"}}
  """
}
