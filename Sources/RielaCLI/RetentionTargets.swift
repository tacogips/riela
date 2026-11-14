import Foundation
import RielaCore

struct RetentionTarget: Equatable, Sendable {
  var kind: RielaRetentionTargetKind
  var root: String
  var sessionStoreRoot: String?
  var memoryRoot: String?
  var logsRoot: String?
  var stateDirectory: String
  var unsafeReason: String?
}

enum RetentionTargetResolver {
  static func resolve(scope: RielaGarbageCollectionScope, homeDirectory: URL, projectDirectory: URL?,
                      explicitSessionStore: String?, environment: [String: String]) -> [RetentionTarget] {
    let manager = FileManager.default
    let homeRoot = standardized(homeDirectory.appendingPathComponent(".riela", isDirectory: true))
    let projectRoot = projectDirectory.map { standardized($0.appendingPathComponent(".riela", isDirectory: true)) }
    var targets: [RetentionTarget] = []

    if scope == .user || scope == .all, manager.fileExists(atPath: homeRoot) {
      targets.append(target(kind: .user, root: homeRoot, sessionStore: homeRoot + "/sessions",
        memory: homeRoot + "/memory", logs: homeRoot + "/logs", state: homeRoot + "/retention"))
    }
    if scope == .project || scope == .all, let projectRoot, projectRoot != homeRoot,
       manager.fileExists(atPath: projectRoot) {
      targets.append(target(kind: .project, root: projectRoot, sessionStore: projectRoot + "/sessions",
        memory: projectRoot + "/memory", logs: projectRoot + "/logs", state: projectRoot + "/retention"))
    }
    if scope == .all,
       let rawStore = [explicitSessionStore, environment["RIELA_SESSION_STORE"]]
        .compactMap({ $0 }).first(where: { !$0.isEmpty }) {
      let base = projectDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      let storeURL = rawStore.hasPrefix("/")
        ? URL(fileURLWithPath: rawStore, isDirectory: true)
        : base.appendingPathComponent(rawStore, isDirectory: true)
      let storeRoot = standardized(storeURL)
      let duplicate = targets.contains { $0.sessionStoreRoot.map(standardizedPath) == storeRoot }
      if !duplicate, manager.fileExists(atPath: storeRoot) {
        let memory = environment["RIELA_MEMORY_ROOT"].flatMap { $0.isEmpty ? nil : standardizedPath($0) }
        targets.append(target(kind: .explicit, root: storeRoot, sessionStore: storeRoot,
          memory: memory, logs: nil, state: storeRoot + "/retention"))
      }
    }
    return targets
  }

  private static func target(kind: RielaRetentionTargetKind, root: String, sessionStore: String?,
                             memory: String?, logs: String?, state: String) -> RetentionTarget {
    let unsafe = (try? TerminalRetentionPaths.checked(root)) == nil
    return RetentionTarget(kind: kind, root: root, sessionStoreRoot: sessionStore, memoryRoot: memory,
      logsRoot: logs, stateDirectory: state, unsafeReason: unsafe ? "unsafePath" : nil)
  }

  private static func standardized(_ url: URL) -> String { standardizedPath(url.path) }

  private static func standardizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
  }
}
