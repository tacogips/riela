import Foundation
import RielaCore
import RielaWork

struct GitRefHandoverSink: HandoverSink {
  let repositoryRoot: URL
  let remote: String
  let runner: any GitCommandRunning
  let environment: [String: String]
  let kind: HandoverSinkKind = .gitRef

  init(
    repositoryRoot: String,
    remote: String,
    runner: any GitCommandRunning = FoundationGitCommandRunner(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.repositoryRoot = URL(fileURLWithPath: repositoryRoot, isDirectory: true).standardizedFileURL
    self.remote = remote
    self.runner = runner
    self.environment = environment
  }

  func write(_ packet: HandoverPacket, bytes: Data, brief: String) async throws -> HandoverSinkRef {
    try validateRemote()
    let refName = try refName(taskId: packet.taskId.rawValue, handoverId: packet.id.rawValue)
    let blob = try run(["hash-object", "-w", "--stdin"], input: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
    guard isObjectID(blob) else { throw HandoverSinkError.gitCommandFailed("git hash-object returned an invalid object id") }
    let remoteObject = try remoteObjectID(refName)
    guard remoteObject == nil || remoteObject == blob else {
      throw HandoverSinkError.conflictingContent("\(remote) \(refName)")
    }
    if let localObject = try localObjectID(refName), localObject != blob {
      throw HandoverSinkError.conflictingContent(refName)
    }
    if try localObjectID(refName) == nil {
      _ = try run(["update-ref", refName, blob])
    }
    if remoteObject == nil {
      _ = try run(["push", remote, "\(refName):\(refName)"])
    }
    return HandoverSinkRef(kind: kind, locator: "\(remote) \(refName)", digest: packet.digest, writtenAt: Date())
  }

  func read(_ ref: HandoverSinkRef) async throws -> Data {
    try validateRemote()
    guard ref.kind == kind else { throw HandoverSinkError.invalidLocator(ref.locator) }
    let pieces = ref.locator.split(separator: " ", omittingEmptySubsequences: false)
    guard pieces.count == 2, String(pieces[0]) == remote, validRefName(String(pieces[1])) else {
      throw HandoverSinkError.invalidLocator(ref.locator)
    }
    let refName = String(pieces[1])
    _ = try run(["fetch", "--no-tags", remote, "\(refName):\(refName)"])
    let object = try localObjectID(refName)
    guard let object else { throw HandoverSinkError.notFound(ref.locator) }
    return try await readBlob(object)
  }

  private func refName(taskId: String, handoverId: String) throws -> String {
    guard safeRefComponent(taskId), safeRefComponent(handoverId) else {
      throw HandoverSinkError.invalidConfiguration("gitRef sink task and handover ids must be valid ref components")
    }
    return "refs/riela/handovers/\(taskId)/\(handoverId)"
  }

  private func safeRefComponent(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && !value.hasPrefix("-")
      && value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
  }

  private func validRefName(_ value: String) -> Bool {
    value.hasPrefix("refs/riela/handovers/")
      && value.range(of: #"^refs/riela/handovers/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
  }

  private func localObjectID(_ refName: String) throws -> String? {
    let result = try execute(["rev-parse", "--verify", "--quiet", refName])
    if result.exitCode == 1 { return nil }
    guard result.exitCode == 0 else { throw GitCommandError(result.output) }
    let object = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isObjectID(object) else { throw HandoverSinkError.gitCommandFailed("git rev-parse returned an invalid object id") }
    return object
  }

  private func remoteObjectID(_ refName: String) throws -> String? {
    let result = try execute(["ls-remote", "--refs", remote, refName])
    guard result.exitCode == 0 else { throw GitCommandError(result.output) }
    guard let line = result.output.split(whereSeparator: \Character.isNewline).first else { return nil }
    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard fields.count == 2, String(fields[1]) == refName, isObjectID(String(fields[0])) else {
      throw HandoverSinkError.gitCommandFailed("git ls-remote returned a malformed ref")
    }
    return String(fields[0])
  }

  private func isObjectID(_ value: String) -> Bool {
    value.count == 40 || value.count == 64
      ? value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
      : false
  }

  private func run(_ arguments: [String], input: Data? = nil) throws -> String {
    let result = try execute(arguments, input: input)
    guard result.exitCode == 0 else { throw GitCommandError(result.output) }
    return result.output
  }

  private func readBlob(_ object: String) async throws -> Data {
    let scratchDirectory = FileManager.default.temporaryDirectory
    let outputURL = scratchDirectory.appendingPathComponent("git-blob-\(UUID().uuidString).tmp")
    guard FileManager.default.createFile(atPath: outputURL.path, contents: Data()) else {
      throw HandoverSinkError.gitCommandFailed("could not create git blob scratch file")
    }
    defer { try? FileManager.default.removeItem(at: outputURL) }
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["cat-file", "blob", object]
    process.currentDirectoryURL = repositoryRoot
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let deadline = Date().addingTimeInterval(30)
    while process.isRunning {
      if Date() >= deadline {
        process.terminate()
        process.waitUntilExit()
        throw HandoverSinkError.commandTimedOut
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    guard process.terminationStatus == 0 else {
      throw HandoverSinkError.gitCommandFailed("git cat-file exited with status \(process.terminationStatus)")
    }
    try output.close()
    return try Data(contentsOf: outputURL)
  }

  private func execute(_ arguments: [String], input: Data? = nil) throws -> GitCommandResult {
    try runner.run(GitCommandInvocation(
      executableURL: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: arguments,
      workingDirectory: repositoryRoot,
      environment: gitEnvironment(),
      standardInput: input,
      deadline: Date().addingTimeInterval(30)
    ))
  }

  private func gitEnvironment() -> [String: String] {
    let preservedKeys = ["HOME", "LANG", "LC_ALL", "LC_CTYPE", "TZ", "SSH_AUTH_SOCK", "PATH"]
    var result = environment.filter { preservedKeys.contains($0.key) }
    result["GIT_TERMINAL_PROMPT"] = "0"
    return result
  }

  private func validateRemote() throws {
    guard !remote.isEmpty, !remote.hasPrefix("-"), !remote.contains(where: \.isWhitespace) else {
      throw HandoverSinkError.invalidConfiguration("gitRef sink remote must be a non-empty git remote or URL")
    }
  }

  private struct GitCommandError: Error, CustomStringConvertible {
    let description: String
    init(_ output: String) { description = "git handover sink command failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))" }
  }
}
