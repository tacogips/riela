import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import RielaCore
import RielaObservability
import RielaServer

public struct RielaAppDaemonEventServeCommand: Equatable, Sendable {
  public var executablePath: String
  public var arguments: [String]
  public var workingDirectory: String
  public var environment: [String: String]
  public var runtimeEnvironmentGeneration: UInt64?
  public var runtimeEnvironmentNames: [String] = []
  public var runtimeEnvironmentValues: [String: String] = [:]

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
  func updateRuntimeEnvironment(generation: UInt64, names: [String], values: [String: String]) async throws
}

public extension RielaAppDaemonEventServeProcessHandle {
  func updateRuntimeEnvironment(generation: UInt64, names: [String], values: [String: String]) async throws {
    throw RuntimeEnvironmentError.notPrepared
  }
}

public protocol RielaAppDaemonEventServeProcessLaunching: Sendable {
  func launch(_ command: RielaAppDaemonEventServeCommand) throws -> any RielaAppDaemonEventServeProcessHandle
}

public struct RielaAppDaemonProcessEventSourceFactory: WorkflowServeEventSourceFactory {
  public var executablePath: String?
  public var launcher: any RielaAppDaemonEventServeProcessLaunching
  public var earlyExitGraceNanoseconds: UInt64
  public var fallbackEnvironmentFileURLs: [URL]

  public init(
    executablePath: String? = nil,
    launcher: any RielaAppDaemonEventServeProcessLaunching = DefaultEventServeProcessLauncher(),
    earlyExitGraceNanoseconds: UInt64 = 300_000_000,
    fallbackEnvironmentFileURLs: [URL] = []
  ) {
    self.executablePath = executablePath
    self.launcher = launcher
    self.earlyExitGraceNanoseconds = earlyExitGraceNanoseconds
    self.fallbackEnvironmentFileURLs = fallbackEnvironmentFileURLs
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
    var command = eventServeCommand(
      workflowDefinitionDirectory: resolvedWorkflow.workflowDirectory ?? request.workingDirectory,
      workingDirectory: request.workingDirectory,
      eventRoot: eventRoot,
      sessionStoreRoot: request.sessionStoreRoot,
      artifactRoot: request.artifactRoot,
      defaultVariables: request.defaultVariables,
      nodePatch: request.nodePatch,
      executablePath: executablePath,
      inheritedEnvironment: request.inheritedEnvironment
    )
    command.runtimeEnvironmentGeneration = request.configuration.runtimeEnvironmentGeneration
    command.runtimeEnvironmentNames = request.configuration.runtimeEnvironmentNames ?? []
    command.runtimeEnvironmentValues = request.configuration.runtimeEnvironmentValues ?? [:]
    if command.runtimeEnvironmentGeneration != nil { command.arguments.append("--runtime-environment-channel") }
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
    if let generation = command.runtimeEnvironmentGeneration {
      do {
        try await process.updateRuntimeEnvironment(generation: generation, names: command.runtimeEnvironmentNames,
          values: command.runtimeEnvironmentValues.filter { command.runtimeEnvironmentNames.contains($0.key) })
      } catch {
        let exited = !process.isRunning
        await process.terminate()
        // An oversized snapshot is rejected before any byte reaches the child.
        if error as? RuntimeEnvironmentError == .outputTooLarge { throw RuntimeEnvironmentError.outputTooLarge }
        // A child that died before acknowledging (missing or incompatible riela)
        // is a startup failure, not an environment preparation failure.
        if exited {
          throw WorkflowServeError.startupFailed(WorkflowServeDiagnostics(
            code: "event_source_process_exited",
            message: earlyExitMessage(process: process),
            selection: request.selection
          ))
        }
        throw RuntimeEnvironmentError.notPrepared
      }
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
    workingDirectory: String? = nil,
    eventRoot: String,
    sessionStoreRoot: String? = nil,
    artifactRoot: String? = nil,
    defaultVariables: JSONObject = [:],
    nodePatch: JSONObject? = nil,
    executablePath: String?,
    inheritedEnvironment: [String: String] = [:]
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
    let processWorkingDirectory = normalizedDirectory(workingDirectory) ?? workflowDefinitionDirectory
    if processWorkingDirectory != workflowDefinitionDirectory {
      serveArguments.append(contentsOf: ["--working-directory", processWorkingDirectory])
    }
    if let sessionStoreRoot, !sessionStoreRoot.isEmpty {
      serveArguments.append(contentsOf: ["--session-store", sessionStoreRoot])
    }
    if let artifactRoot, !artifactRoot.isEmpty {
      serveArguments.append(contentsOf: ["--artifact-root", artifactRoot])
    }
    if !defaultVariables.isEmpty, let serializedVariables = serializedJSONObject(defaultVariables) {
      serveArguments.append(contentsOf: ["--variables", serializedVariables])
    }
    if let nodePatch, let serializedPatch = serializedNodePatch(nodePatch) {
      serveArguments.append(contentsOf: ["--node-patch", serializedPatch])
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
      workingDirectory: processWorkingDirectory,
      environment: eventServeEnvironment(
        workflowDefinitionDirectory: workflowDefinitionDirectory,
        eventRoot: eventRoot,
        inheritedEnvironment: inheritedEnvironment
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

  private func serializedNodePatch(_ nodePatch: JSONObject) -> String? {
    serializedJSONObject(nodePatch)
  }

  private func serializedJSONObject(_ object: JSONObject) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(JSONValue.object(object)) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  private func normalizedDirectory(_ path: String?) -> String? {
    guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
      return nil
    }
    return path
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
    eventRoot: String,
    inheritedEnvironment: [String: String]
  ) -> [String: String] {
    var environment = inheritedEnvironment.isEmpty ? fallbackEnvironment() : inheritedEnvironment
    let telemetryEnvironment = telemetryChildProcessEnvironment(
      from: inheritedEnvironment.isEmpty ? fallbackEnvironment() : inheritedEnvironment,
      additionalResourceAttributes: [
        "runtime.surface": "events-serve",
        "riela.parent.surface": "riela-app",
        "workflow.id": URL(fileURLWithPath: workflowDefinitionDirectory).lastPathComponent,
        "event.source.id": URL(fileURLWithPath: eventRoot).lastPathComponent
      ]
    )
    environment.merge(telemetryEnvironment) { _, telemetryValue in telemetryValue }
    return environment
  }

  private func fallbackEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    for url in fallbackEnvironmentFileURLs {
      environment.merge(RielaAppEnvironmentFileStore.parseEnvironmentFile(url)) { _, fileValue in fileValue }
    }
    return environment
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
    process.environment = command.environment.filter { command.runtimeEnvironmentGeneration == nil || !command.runtimeEnvironmentNames.contains($0.key) }
    let input = command.runtimeEnvironmentGeneration == nil ? nil : Pipe()
    if let input {
      process.standardInput = input
      disableSigpipe(input.fileHandleForWriting.fileDescriptor)
      // Frame writes are bounded by the ACK deadline instead of blocking on a full pipe.
      let descriptor = input.fileHandleForWriting.fileDescriptor
      _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    }
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    let handle = FoundationEventServeProcessHandle(
      process: process,
      outputPipe: output,
      errorPipe: error, inputPipe: input
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

  public func updateRuntimeEnvironment(generation: UInt64, names: [String], values: [String: String]) async throws {
    do {
      try await process.updateRuntimeEnvironment(generation: generation, names: names, values: values)
    } catch let error as RuntimeEnvironmentError where error == .outputTooLarge || error == .reloadInProgress {
      // Rejected before any byte reached the child: it still runs its current generation.
      throw error
    } catch {
      // An ACK may be lost after installation. Reap the uncertain child before
      // keeping the parent's previous snapshot; never leave split generations.
      await process.terminate()
      throw error
    }
  }

  public func shutdown() async throws {
    await process.terminate()
  }
}

private final class FoundationEventServeProcessHandle: RielaAppDaemonEventServeProcessHandle, @unchecked Sendable {
  private let process: Process
  private let outputPipe: Pipe
  private let errorPipe: Pipe
  private let inputPipe: Pipe?
  private var acknowledgementBuffer = Data()
  private var acknowledgements: [UInt64: Bool] = [:]
  private var acknowledgedNames: [UInt64: [String]] = [:]
  /// Managed children: partial stderr line and the bounded tail of safe codes.
  private var diagnosticBuffer = Data()
  private var diagnosticCodes: [String] = []
  private var frameWriteInProgress = false
  private var inputClosed = false
  private let lock = NSLock()
  private var outputBuffer = Data()
  private var errorBuffer = Data()

  init(process: Process, outputPipe: Pipe, errorPipe: Pipe, inputPipe: Pipe? = nil) {
    self.inputPipe = inputPipe
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
    let running = process.isRunning
    return lock.withLock {
      if inputPipe != nil {
        // Managed children only surface stable safe codes, never raw output.
        var codes = diagnosticCodes
        if !running, let code = managedChildDiagnosticCode(diagnosticBuffer) { codes.append(code) }
        return codes.joined(separator: "\n")
      }
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

  func updateRuntimeEnvironment(generation: UInt64, names: [String], values: [String: String]) async throws {
    guard let inputPipe, isRunning, Set(values.keys).isSubset(of: Set(names)) else { throw RuntimeEnvironmentError.notPrepared }
    // The child closes its channel permanently on an oversized frame; reject it here first.
    let data = try RuntimeEnvironmentChannelFrame(generation: generation, managedNames: names, values: values).encodedLine()
    // Interleaved partial writes would corrupt both frames.
    let claimed = lock.withLock { () -> Bool in
      guard !frameWriteInProgress else { return false }
      frameWriteInProgress = true
      return true
    }
    guard claimed else { throw RuntimeEnvironmentError.reloadInProgress }
    defer { lock.withLock { frameWriteInProgress = false } }
    let deadline = ProcessInfo.processInfo.systemUptime + Self.acknowledgementTimeoutSeconds
    try await writeFrame(data, to: inputPipe.fileHandleForWriting.fileDescriptor, deadline: deadline)
    while ProcessInfo.processInfo.systemUptime < deadline {
      let result = lock.withLock { acknowledgements[generation].map { ($0, acknowledgedNames[generation] ?? []) } }
      if let result {
        guard result.0, Set(result.1) == Set(names) else { throw RuntimeEnvironmentError.outputInvalid }
        return
      }
      guard isRunning else { throw RuntimeEnvironmentError.sourceFailed }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw RuntimeEnvironmentError.sourceTimeout
  }

  static let acknowledgementTimeoutSeconds: TimeInterval = 10

  /// Non-blocking write bounded by the ACK deadline; a child that stops reading
  /// cannot park this task on a full pipe.
  private func writeFrame(_ data: Data, to descriptor: Int32, deadline: TimeInterval) async throws {
    var offset = 0
    while offset < data.count {
      guard !lock.withLock({ inputClosed }) else { throw RuntimeEnvironmentError.sourceFailed }
      let written = data.withUnsafeBytes { bytes in
        write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
      }
      if written > 0 { offset += written; continue }
      let code = errno
      guard written < 0, code == EAGAIN || code == EWOULDBLOCK || code == EINTR else { throw RuntimeEnvironmentError.sourceFailed }
      guard isRunning else { throw RuntimeEnvironmentError.sourceFailed }
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw RuntimeEnvironmentError.sourceTimeout }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  func terminate() async {
    // EOF releases a managed child still waiting for its first frame.
    lock.withLock { inputClosed = true }
    try? inputPipe?.fileHandleForWriting.close()
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
    if inputPipe != nil {
      // A managed child can print arbitrary diagnostics. Retain only typed ACKs
      // and a bounded tail of stderr lines that are stable safe codes.
      guard !isError else {
        lock.withLock {
          diagnosticBuffer.append(data)
          while let end = diagnosticBuffer.firstIndex(of: 10) {
            let line = diagnosticBuffer.prefix(upTo: end); diagnosticBuffer.removeSubrange(...end)
            guard let code = managedChildDiagnosticCode(line) else { continue }
            diagnosticCodes.append(code)
            if diagnosticCodes.count > 8 { diagnosticCodes.removeFirst(diagnosticCodes.count - 8) }
          }
          if diagnosticBuffer.count > 4_096 { diagnosticBuffer.removeAll() }
        }
        return
      }
      lock.withLock {
        acknowledgementBuffer.append(data)
        if acknowledgementBuffer.count > 1_048_576 { acknowledgementBuffer.removeAll(); return }
        while let end = acknowledgementBuffer.firstIndex(of: 10) {
          let line = acknowledgementBuffer.prefix(upTo: end); acknowledgementBuffer.removeSubrange(...end)
          guard let ack = RuntimeEnvironmentChannelAcknowledgement.decodeLine(Data(line)),
            let generation = ack.generation else { continue }
          acknowledgements[generation] = ack.accepted
          acknowledgedNames[generation] = ack.names
          if acknowledgements.count > 8, let first = acknowledgements.keys.min() {
            acknowledgements.removeValue(forKey: first); acknowledgedNames.removeValue(forKey: first)
          }
        }
      }
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

/// Managed-child stderr is reduced to stable safe codes such as
/// `environment_required_missing`; anything else (free text, values) is dropped.
func managedChildDiagnosticCode(_ line: Data) -> String? {
  guard line.count <= 160, var text = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
    return nil
  }
  if text.hasPrefix("error: ") { text.removeFirst("error: ".count) }
  guard text.count <= 96, ["environment_", "event_", "workflow_"].contains(where: { text.hasPrefix($0) && text.count > $0.count }),
    text.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || $0 == "_" }) else { return nil }
  return text
}

/// A child that exits before reading its frame must fail the write, not kill the app.
private func disableSigpipe(_ fileDescriptor: Int32) {
  #if canImport(Darwin)
  _ = fcntl(fileDescriptor, F_SETNOSIGPIPE, 1)
  #else
  _ = signal(SIGPIPE, SIG_IGN)
  #endif
}
