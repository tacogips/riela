import Foundation
import RielaCore
import RielaMemory
import RielaObservability
import RielaWork

enum BotMemoryRuntime {
  static func memoryRoot(explicit: String? = nil, workingDirectory: String, environment: [String: String]) -> String {
    if let explicit { return explicit }
    if let root = environment["RIELA_MEMORY_ROOT"], !root.isEmpty { return root }
    return RielaMemoryStore.defaultRootDirectory(workingDirectory: workingDirectory)
  }

  static func redactionRules(environment: [String: String]) -> HandoverRedactionRules {
    HandoverRedactionRules(boundValues: environment.keys.sorted().reduce(into: [:]) { secrets, key in
      let parts = key.uppercased().split(separator: "_")
      if parts.contains(where: { ["KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL"].contains($0) }),
        let value = environment[key], secrets[value] == nil {
        secrets[value] = key
      }
    })
  }

  static func writer(
    sessionStoreRoot: String, memoryRoot: String, environment: [String: String], now: @escaping @Sendable () -> Date = Date.init
  ) -> BotMemoryWriter {
    let rules = redactionRules(environment: environment)
    return BotMemoryWriter(
      botStore: BotStore(sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot)),
      memoryRoot: memoryRoot, redact: { rules.redactText($0) }, now: now
    )
  }

  static func promptBlock(
    botId: String, sessionStoreRoot: String, workingDirectory: String, environment: [String: String]
  ) -> String? {
    do {
      let root = memoryRoot(workingDirectory: workingDirectory, environment: environment)
      let writer = writer(sessionStoreRoot: sessionStoreRoot, memoryRoot: root, environment: environment)
      return try BotMemoryMarkdown.promptBlock(entries: writer.entries(botId: botId), limitBytes: BotMemoryLimits().promptBlockBytes)
    } catch {
      RielaStandardStreams.writeError("riela bot memory: \(error)\n")
      return nil
    }
  }
}
