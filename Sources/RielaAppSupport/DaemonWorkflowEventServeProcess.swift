#if os(macOS)
import Foundation
import RielaObservability
import RielaServer

public struct RielaAppDaemonEventServeCommand: Equatable, Sendable {
  public var executablePath: String
  public var arguments: [String]
  public var workingDirectory: String
  public var environment: [String: String]

  public init(
    executablePath: String,
    arguments: [String],
    workingDirectory: String,
    environment: [String: String]
  ) {
    self.executablePath = executablePath
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environment = environment
  }
}

public protocol RielaAppDaemonEventServeProcessHandle: Sendable {
  var processIdentifier: Int32 { get }
  var isRunning: Bool { get }
  var terminationStatus: Int32? { get }
  var capturedOutput: String { get }
  func terminate() async
}

public protocol RielaAppDaemonEventServeProcessLaunching: Sendable {
  func launch(_ command: RielaAppDaemonEventServeCommand) throws -> any RielaAppDaemonEventServeProcessHandle
}

public struct RielaAppDaemonProcessEventSourceFactory: WorkflowServeEventSourceFactory {
  public var executablePath: String?
  public var launcher: any RielaAppDaemonEventServeProcessLaunching
  public var earlyExitGraceNanoseconds: UInt64
  public var environmentFileURLs: [URL]

  public init(
    executablePath: String? = nil,
    launcher: any RielaAppDaemonEventServeProcessLaunching = DefaultEventServeProcessLauncher(),
    earlyExitGraceNanoseconds: UInt64 = 300_000_000,
    environmentFileURLs: [URL] = Self.defaultEnvironmentFileURLs()
  ) {
    self.executablePath = executablePath
    self.launcher = launcher
    self.earlyExitGraceNanoseconds = earlyExitGraceNanoseconds
    self.environmentFileURLs = environmentFileURLs
  }

  public func startEventSources(
    for resolvedWorkflow: WorkflowServeResolvedWorkflow,
    request: WorkflowServeStartRequest,
    generationId: String
  ) async throws -> [any WorkflowServeEventSourceHandle] {
    guard request.startsEventSources else {
      return []
    }
    guard let eventRoot = request.eventRoot, !eventRoot.isEmpty else {
      return []
    }
    let command = eventServeCommand(
      workflowDefinitionDirectory: request.workingDirectory,
      eventRoot: eventRoot,
      sessionStoreRoot: request.sessionStoreRoot,
      artifactRoot: request.artifactRoot,
      executablePath: executablePath
    )
    logEventServe("launch \(command.executablePath) \(command.arguments.joined(separator: " ")) cwd=\(command.workingDirectory)")
    let process: any RielaAppDaemonEventServeProcessHandle
    do {
      process = try launcher.launch(command)
      logEventServe("launched pid=\(process.processIdentifier)")
    } catch {
      throw WorkflowServeError.startupFailed(WorkflowServeDiagnostics(
        code: "event_source_process_launch_failed",
        message: "failed to launch riela events serve: \(error)",
        selection: request.selection
      ))
    }
    if earlyExitGraceNanoseconds > 0 {
      try? await Task.sleep(nanoseconds: earlyExitGraceNanoseconds)
    }
    guard process.isRunning else {
      throw WorkflowServeError.startupFailed(WorkflowServeDiagnostics(
        code: "event_source_process_exited",
        message: earlyExitMessage(process: process),
        selection: request.selection
      ))
    }
    logEventServe("pid=\(process.processIdentifier) running after startup grace")
    return [
      EventServeSourceHandle(
        process: process,
        sourceId: "riela-events-serve",
        generationId: generationId
      )
    ]
  }

  public func eventServeCommand(
    workflowDefinitionDirectory: String,
    eventRoot: String,
    sessionStoreRoot: String? = nil,
    artifactRoot: String? = nil,
    executablePath: String?
  ) -> RielaAppDaemonEventServeCommand {
    let executable = resolveExecutablePath(executablePath)
    var serveArguments = [
      "events",
      "serve",
      "--workflow-definition-dir",
      workflowDefinitionDirectory,
      "--event-root",
      eventRoot
    ]
    if let sessionStoreRoot, !sessionStoreRoot.isEmpty {
      serveArguments.append(contentsOf: ["--session-store", sessionStoreRoot])
    }
    if let artifactRoot, !artifactRoot.isEmpty {
      serveArguments.append(contentsOf: ["--artifact-root", artifactRoot])
    }
    let arguments: [String]
    if executable == "/usr/bin/env" {
      arguments = ["riela"] + serveArguments
    } else {
      arguments = serveArguments
    }
    return RielaAppDaemonEventServeCommand(
      executablePath: executable,
      arguments: arguments,
      workingDirectory: workflowDefinitionDirectory,
      environment: eventServeEnvironment(
        workflowDefinitionDirectory: workflowDefinitionDirectory,
        eventRoot: eventRoot
      )
    )
  }

  public func resolvedExecutablePath() -> String {
    resolveExecutablePath(executablePath)
  }

  public func resolvedExecutableDescription() -> String {
    Self.executableDescription(for: resolvedExecutablePath())
  }

  public static func executableDescription(for resolvedExecutablePath: String) -> String {
    resolvedExecutablePath == "/usr/bin/env" ? "PATH lookup: riela" : resolvedExecutablePath
  }

  public static func defaultEnvironmentFileURLs() -> [URL] {
    let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    return [
      home.appendingPathComponent(".riela/rielaapp.env"),
      home.appendingPathComponent(".riela/env")
    ]
  }

  private func resolveExecutablePath(_ configuredPath: String?) -> String {
    if let configuredPath, FileManager.default.isExecutableFile(atPath: configuredPath) {
      return configuredPath
    }
    if let environmentPath = ProcessInfo.processInfo.environment["RIELA_APP_RIELA_EXECUTABLE"],
      FileManager.default.isExecutableFile(atPath: environmentPath) {
      return environmentPath
    }
    if let sibling = Bundle.main.executableURL?
      .deletingLastPathComponent()
      .appendingPathComponent("riela")
      .path,
      FileManager.default.isExecutableFile(atPath: sibling) {
      return sibling
    }
    return "/usr/bin/env"
  }

  private func earlyExitMessage(process: any RielaAppDaemonEventServeProcessHandle) -> String {
    let status = process.terminationStatus.map(String.init) ?? "unknown"
    let output = process.capturedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !output.isEmpty else {
      return "riela events serve exited before becoming ready with status \(status)"
    }
    return "riela events serve exited before becoming ready with status \(status): \(output)"
  }

  private func eventServeEnvironment(
    workflowDefinitionDirectory: String,
    eventRoot: String
  ) -> [String: String] {
    telemetryChildProcessEnvironment(
      from: mergedEnvironment(),
      additionalResourceAttributes: [
        "runtime.surface": "events-serve",
        "riela.parent.surface": "riela-app",
        "workflow.id": URL(fileURLWithPath: workflowDefinitionDirectory).lastPathComponent,
        "event.source.id": URL(fileURLWithPath: eventRoot).lastPathComponent
      ]
    )
  }

  private func mergedEnvironment() -> [String: String] {
    var environment = environmentFileURLs.reduce(into: [String: String]()) { result, url in
      result.merge(Self.parseEnvironmentFile(url)) { current, _ in current }
    }
    environment.merge(ProcessInfo.processInfo.environment) { _, processValue in processValue }
    return environment
  }

  private static func parseEnvironmentFile(_ url: URL) -> [String: String] {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
      return [:]
    }
    var values: [String: String] = [:]
    for rawLine in contents.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("#") else {
        continue
      }
      let assignment = line.hasPrefix("export ")
        ? String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
        : line
      guard let separator = assignment.firstIndex(of: "=") else {
        continue
      }
      let key = assignment[..<separator].trimmingCharacters(in: .whitespaces)
      guard isValidEnvironmentKey(key) else {
        continue
      }
      let value = assignment[assignment.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      values[key] = unquotedEnvironmentValue(String(value))
    }
    return values
  }

  private static func isValidEnvironmentKey(_ key: String) -> Bool {
    guard let first = key.first, first == "_" || first.isLetter else {
      return false
    }
    return key.allSatisfy { character in
      character == "_" || character.isLetter || character.isNumber
    }
  }

  private static func unquotedEnvironmentValue(_ value: String) -> String {
    guard value.count >= 2,
      let first = value.first,
      let last = value.last,
      (first == "\"" && last == "\"") || (first == "'" && last == "'")
    else {
      return value
    }
    return String(value.dropFirst().dropLast())
  }
}

private func logEventServe(_ message: String) {
  let line = "[RielaApp daemon event-serve] \(message)\n"
  if let data = line.data(using: .utf8) {
    FileHandle.standardError.write(data)
  }
}

public struct DefaultEventServeProcessLauncher: RielaAppDaemonEventServeProcessLaunching {
  public init() {}

  public func launch(_ command: RielaAppDaemonEventServeCommand) throws -> any RielaAppDaemonEventServeProcessHandle {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command.executablePath)
    process.arguments = command.arguments
    process.currentDirectoryURL = URL(fileURLWithPath: command.workingDirectory, isDirectory: true)
    process.environment = command.environment
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    let handle = FoundationEventServeProcessHandle(
      process: process,
      outputPipe: output,
      errorPipe: error
    )
    try process.run()
    handle.startCapturing()
    return handle
  }
}

private final class EventServeSourceHandle: WorkflowServeEventSourceHandle, @unchecked Sendable {
  private let process: any RielaAppDaemonEventServeProcessHandle
  private let sourceId: String
  private let generationId: String

  public var status: WorkflowServeEventSourceStatus {
    WorkflowServeEventSourceStatus(
      sourceId: sourceId,
      status: process.isRunning ? "running" : "exited",
      generationId: generationId
    )
  }

  init(
    process: any RielaAppDaemonEventServeProcessHandle,
    sourceId: String,
    generationId: String
  ) {
    self.process = process
    self.sourceId = sourceId
    self.generationId = generationId
  }

  public func shutdown() async throws {
    await process.terminate()
  }
}

private final class FoundationEventServeProcessHandle: RielaAppDaemonEventServeProcessHandle, @unchecked Sendable {
  private let process: Process
  private let outputPipe: Pipe
  private let errorPipe: Pipe
  private let lock = NSLock()
  private var outputBuffer = Data()
  private var errorBuffer = Data()

  init(process: Process, outputPipe: Pipe, errorPipe: Pipe) {
    self.process = process
    self.outputPipe = outputPipe
    self.errorPipe = errorPipe
  }

  var processIdentifier: Int32 {
    process.processIdentifier
  }

  var isRunning: Bool {
    process.isRunning
  }

  var terminationStatus: Int32? {
    process.isRunning ? nil : process.terminationStatus
  }

  var capturedOutput: String {
    lock.withLock {
      let data = outputBuffer + errorBuffer
      return String(data: data, encoding: .utf8) ?? ""
    }
  }

  func startCapturing() {
    process.terminationHandler = { [weak self] process in
      self?.appendProcessTermination(process.terminationStatus)
    }
    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.appendOutput(handle.availableData, isError: false)
    }
    errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.appendOutput(handle.availableData, isError: true)
    }
  }

  func terminate() async {
    guard process.isRunning else {
      closePipes()
      return
    }
    let process = process
    process.terminate()
    await Task.detached {
      process.waitUntilExit()
    }.value
    closePipes()
  }

  private func appendOutput(_ data: Data, isError: Bool) {
    guard !data.isEmpty else {
      return
    }
    lock.withLock {
      if isError {
        errorBuffer.append(data)
      } else {
        outputBuffer.append(data)
      }
      trimBuffers()
    }
  }

  private func appendProcessTermination(_ status: Int32) {
    let output = capturedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    if output.isEmpty {
      logEventServe("pid=\(process.processIdentifier) exited status=\(status)")
    } else {
      logEventServe("pid=\(process.processIdentifier) exited status=\(status): \(output)")
    }
  }

  private func trimBuffers() {
    let maximumBytes = 16_384
    if outputBuffer.count > maximumBytes {
      outputBuffer.removeFirst(outputBuffer.count - maximumBytes)
    }
    if errorBuffer.count > maximumBytes {
      errorBuffer.removeFirst(errorBuffer.count - maximumBytes)
    }
  }

  private func closePipes() {
    outputPipe.fileHandleForReading.readabilityHandler = nil
    errorPipe.fileHandleForReading.readabilityHandler = nil
  }
}
#endif
