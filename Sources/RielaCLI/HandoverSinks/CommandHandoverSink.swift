import Foundation
import RielaAdapters
import RielaCore
import RielaWork

struct CommandHandoverSink: HandoverSink {
  let argv: [String]
  let timeoutSeconds: TimeInterval
  let workingDirectory: URL
  let runner: any LocalProcessRunning
  let kind: HandoverSinkKind = .command

  init(argv: [String], timeoutSeconds: TimeInterval = 30, workingDirectory: String = FileManager.default.currentDirectoryPath,
       runner: any LocalProcessRunning = FoundationLocalProcessRunner()) {
    self.argv = argv
    self.timeoutSeconds = timeoutSeconds
    self.workingDirectory = URL(fileURLWithPath: workingDirectory, isDirectory: true)
    self.runner = runner
  }

  func write(_ packet: HandoverPacket, bytes: Data, brief: String) async throws -> HandoverSinkRef {
    let result = try await run(argv, stdin: bytes)
    guard result.terminationStatus == 0 else { throw HandoverSinkError.commandFailed(result.terminationStatus) }
    guard let id = result.stdout.components(separatedBy: .newlines).first?
      .trimmingCharacters(in: .whitespacesAndNewlines), validIdentifier(id) else {
      throw HandoverSinkError.invalidCommandOutput
    }
    return HandoverSinkRef(kind: kind, locator: id, digest: packet.digest, writtenAt: Date())
  }

  func read(_ ref: HandoverSinkRef) async throws -> Data {
    guard ref.kind == kind, validIdentifier(ref.locator) else { throw HandoverSinkError.invalidLocator(ref.locator) }
    let result = try await run(argv + ["--read", ref.locator], stdin: Data())
    guard result.terminationStatus == 0 else { throw HandoverSinkError.commandFailed(result.terminationStatus) }
    return Data(result.stdout.utf8)
  }

  private func run(_ command: [String], stdin: Data) async throws -> LocalProcessResult {
    guard let executable = command.first, !executable.isEmpty else {
      throw HandoverSinkError.invalidConfiguration("command sink argv must not be empty")
    }
    let executableURL: URL
    let arguments: [String]
    if executable.contains("/") {
      executableURL = URL(fileURLWithPath: executable)
      arguments = Array(command.dropFirst())
    } else {
      executableURL = URL(fileURLWithPath: "/usr/bin/env")
      arguments = command
    }
    guard let input = String(data: stdin, encoding: .utf8) else { throw HandoverSinkError.invalidPacketEncoding }
    let config = LocalProcessConfiguration(
      executableURL: executableURL,
      arguments: arguments,
      workingDirectoryURL: workingDirectory
    )
    return try await runner.run(configuration: config, stdin: input, deadline: Date().addingTimeInterval(timeoutSeconds))
  }

  private func validIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256 && !value.contains(where: { $0.isWhitespace || $0.isNewline })
  }
}
