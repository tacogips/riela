import Foundation
import RielaAdapters

/// Worker subprocesses receive only the workspace's explicitly selected host
/// environment plus the invocation's own values, never implicit ambient secrets.
struct DistributedWorkerProcessRunner: LocalProcessRunning {
  let environment: [String: String]

  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    var scoped = configuration
    scoped.unsetEnvironmentKeys.formUnion(ProcessInfo.processInfo.environment.keys)
    scoped.environment = environment.filter { !configuration.unsetEnvironmentKeys.contains($0.key) }
      .merging(configuration.environment) { _, explicit in explicit }
    return try await FoundationLocalProcessRunner().run(configuration: scoped, stdin: stdin, deadline: deadline)
  }
}
