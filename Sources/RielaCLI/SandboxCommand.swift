import ArgumentParser
import Foundation
import RielaAdapters
import RielaCore

private struct SandboxRunArguments: ParsableArguments {
  @Option var backend: String?
  @Option var options: String?
  @Option(name: .customLong("working-dir")) var workingDirectory: String?
  @Option(name: .customLong("read-path")) var readPaths: [String] = []
  @Option(name: .customLong("write-path")) var writePaths: [String] = []
  @Option(name: .customLong("credential-path")) var credentialPaths: [String] = []
  @Option(name: .customLong("env")) var environmentNames: [String] = []
  @Flag var allowNetwork = false
  @Option var containerImage: String?
  @Option var timeoutMs: Int = 120_000
  @Argument(parsing: .captureForPassthrough) var command: [String] = []
}

struct SandboxCommand: Sendable {
  var environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
  var runner: any LocalProcessRunning = FoundationLocalProcessRunner()
  var directoryParent: URL?

  func run(_ arguments: [String]) async -> CLICommandResult {
    do {
      if arguments == ["--help"] || arguments == ["run", "--help"] {
        return .init(exitCode: .success, stdout: "riela sandbox run [options] -- executable [arguments]\n" + SandboxRunArguments.helpMessage())
      }
      guard arguments.first == "run" else {
        throw CLIUsageError("usage: riela sandbox run --backend auto|container|seatbelt|bubblewrap [options] -- executable [arguments]")
      }
      let parsed = try SandboxRunArguments.parse(Array(arguments.dropFirst()))
      let commandArguments = parsed.command.first == "--" ? Array(parsed.command.dropFirst()) : parsed.command
      guard parsed.timeoutMs > 0, let command = commandArguments.first else {
        throw CLIUsageError("sandbox run requires a command and a positive --timeout-ms")
      }
      let workspace = URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath,
        isDirectory: true).standardizedFileURL
      var options = try parsed.options.map {
        let object = try JSONReferenceLoader().object(from: $0, workingDirectory: workspace.path)
        return try JSONDecoder().decode(WorkflowExecutionSandbox.self, from: JSONEncoder().encode(object))
      } ?? .init()
      if let raw = parsed.backend {
        guard let backend = WorkflowSandboxBackend(rawValue: raw) else { throw CLIUsageError("invalid sandbox backend '\(raw)'") }
        options.backend = backend
      }
      options.readPaths += parsed.readPaths
      options.writePaths += parsed.writePaths
      options.credentialPaths += parsed.credentialPaths
      options.environment += parsed.environmentNames
      if parsed.allowNetwork { options.networkPolicy = .egressAllowed }
      if let image = parsed.containerImage {
        options.container = .init(image: image)
        if parsed.backend == nil { options.backend = .container }
      }
      let executable: URL
      if options.backend == .container {
        // Image executables need not exist on the coordinator host. The
        // original command is resolved against the image PATH below.
        executable = URL(fileURLWithPath: command, relativeTo: workspace).absoluteURL
      } else if command.hasPrefix("/") {
        executable = URL(fileURLWithPath: command)
      } else if command.contains("/") {
        executable = workspace.appendingPathComponent(command)
      } else {
        let path = (environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":")
          .map { URL(fileURLWithPath: String($0)).appendingPathComponent(command) }
          .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let path else { throw CLIUsageError("sandbox command executable '\(command)' was not found") }
        executable = path
      }
      let directory = try SandboxExecutionDirectory(parent: directoryParent ?? FileManager.default.temporaryDirectory)
      defer { withExtendedLifetime(directory) {} }
      let configuration = try ExecutionSandboxLauncher(environment: environment).process(executable: executable,
        arguments: Array(commandArguments.dropFirst()), workspace: workspace, options: options, directory: directory,
        containerExecutable: command)
      let result = try await runner.run(configuration: configuration, stdin: "",
        deadline: Date().addingTimeInterval(Double(parsed.timeoutMs) / 1_000))
      return .init(exitCode: result.terminationStatus == 0 ? .success : .failure, stdout: result.stdout, stderr: result.stderr)
    } catch {
      return .init(exitCode: .failure, stderr: "\(error)")
    }
  }
}
