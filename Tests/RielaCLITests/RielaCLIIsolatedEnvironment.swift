import Foundation
import RielaWorkflowRegistry

struct RielaCLIIsolatedEnvironment {
  let root: URL
  let home: URL
  let project: URL
  let environment: [String: String]

  static func make(_ name: String, extra: [String: String] = [:]) throws -> Self {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    let home = root.appendingPathComponent("home", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let process = ProcessInfo.processInfo.environment
    var environment = ["HOME": home.path]
    for key in ["PATH", "TMPDIR"] {
      if let value = process[key] { environment[key] = value }
    }
    environment.merge(extra) { _, new in new }
    return Self(root: root, home: home, project: project, environment: environment)
  }

  func run<T>(_ body: () throws -> T) rethrows -> T {
    try CLIRuntimeEnvironment.$captured.withValue(environment, operation: body)
  }

  func run<T>(_ body: () async throws -> T) async rethrows -> T {
    try await CLIRuntimeEnvironment.$captured.withValue(environment, operation: body)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
