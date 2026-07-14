import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct AppleGatewayProcessRunner {
  private static let pipeCloseGraceInterval: TimeInterval = 0.25
  private static let childEnvironmentAllowlist = [
    "HOME",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "LOGNAME",
    "PATH",
    "TMPDIR",
    "USER",
    "__CF_USER_TEXT_ENCODING"
  ]

  var runtimeEnvironment: [String: String]

  func run(
    executablePath: String,
    arguments: [String],
    deadline: Date?,
    allowNonzeroExit: Bool = false
  ) throws -> AppleGatewayProcessOutput {
    let output = try runData(
      executablePath: executablePath,
      arguments: arguments,
      deadline: deadline,
      allowNonzeroExit: allowNonzeroExit
    )
    let stdout = String(data: output.stdoutData, encoding: .utf8) ?? ""
    let stderr = String(data: output.stderrData, encoding: .utf8) ?? ""
    return AppleGatewayProcessOutput(stdout: stdout, stderr: stderr, terminationStatus: output.terminationStatus)
  }

  func runData(
    executablePath: String,
    arguments: [String],
    deadline: Date?,
    allowNonzeroExit: Bool = false
  ) throws -> AppleGatewayProcessDataOutput {
    #if canImport(Darwin) || canImport(Glibc)
    return try runInIsolatedProcessGroup(
      executablePath: executablePath,
      arguments: arguments,
      deadline: deadline,
      allowNonzeroExit: allowNonzeroExit
    )
    #else
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.environment = sanitizedChildEnvironment()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    let termination = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in
      termination.signal()
    }
    do {
      try process.run()
    } catch {
      throw AdapterExecutionError(.providerError, "apple-gateway failed to start: \(error.localizedDescription)")
    }
    let stdoutDrain = AppleGatewayPipeDrain(
      handle: outputPipe.fileHandleForReading,
      label: "riela.apple-gateway.stdout"
    )
    let stderrDrain = AppleGatewayPipeDrain(
      handle: errorPipe.fileHandleForReading,
      label: "riela.apple-gateway.stderr"
    )
    if !waitForAppleGatewayProcess(process, termination: termination, until: deadline) {
      terminateAppleGatewayProcess(process, termination: termination)
      stdoutDrain.cancel()
      stderrDrain.cancel()
      _ = stdoutDrain.waitForData(timeout: .now() + 1)
      _ = stderrDrain.waitForData(timeout: .now() + 1)
      throw AdapterExecutionError(.timeout, "apple-gateway exceeded deadline and was terminated")
    }
    process.terminationHandler = nil
    let stdoutData = try collectPipeDataAfterTermination(
      stdoutDrain,
      deadline: deadline,
      streamName: "stdout"
    )
    let stderrData = try collectPipeDataAfterTermination(
      stderrDrain,
      deadline: deadline,
      streamName: "stderr"
    )
    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 || allowNonzeroExit else {
      let detail = appleGatewayCompactText(stderr.isEmpty ? stdout : stderr)
      throw AdapterExecutionError(.providerError, "apple-gateway failed with exit code \(process.terminationStatus): \(detail)")
    }
    return AppleGatewayProcessDataOutput(
      stdoutData: stdoutData,
      stderrData: stderrData,
      terminationStatus: process.terminationStatus
    )
    #endif
  }

  private func sanitizedChildEnvironment() -> [String: String] {
    var childEnvironment: [String: String] = [:]
    for name in Self.childEnvironmentAllowlist {
      guard let value = runtimeEnvironment[name], !value.isEmpty else {
        continue
      }
      childEnvironment[name] = value
    }
    return childEnvironment
  }

  #if canImport(Darwin) || canImport(Glibc)
  private func runInIsolatedProcessGroup(
    executablePath: String,
    arguments: [String],
    deadline: Date?,
    allowNonzeroExit: Bool = false
  ) throws -> AppleGatewayProcessDataOutput {
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let pid = try spawnProcessGroup(
      executablePath: executablePath,
      arguments: arguments,
      environment: sanitizedChildEnvironment(),
      stdoutPipe: outputPipe,
      stderrPipe: errorPipe
    )
    outputPipe.fileHandleForWriting.closeFile()
    errorPipe.fileHandleForWriting.closeFile()
    let termination = AppleGatewayProcessTermination(pid: pid)
    let stdoutDrain = AppleGatewayPipeDrain(
      handle: outputPipe.fileHandleForReading,
      label: "riela.apple-gateway.stdout"
    )
    let stderrDrain = AppleGatewayPipeDrain(
      handle: errorPipe.fileHandleForReading,
      label: "riela.apple-gateway.stderr"
    )
    if !termination.wait(until: deadline) {
      terminateAppleGatewayProcessGroup(pid: pid, termination: termination)
      stdoutDrain.cancel()
      stderrDrain.cancel()
      _ = stdoutDrain.waitForData(timeout: .now() + 1)
      _ = stderrDrain.waitForData(timeout: .now() + 1)
      throw AdapterExecutionError(.timeout, "apple-gateway exceeded deadline and was terminated")
    }
    let stdoutData = try collectPipeDataAfterTermination(
      stdoutDrain,
      deadline: deadline,
      streamName: "stdout"
    )
    let stderrData = try collectPipeDataAfterTermination(
      stderrDrain,
      deadline: deadline,
      streamName: "stderr"
    )
    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
    let terminationStatus = termination.exitStatus()
    guard terminationStatus == 0 || allowNonzeroExit else {
      let detail = appleGatewayCompactText(stderr.isEmpty ? stdout : stderr)
      throw AdapterExecutionError(.providerError, "apple-gateway failed with exit code \(terminationStatus): \(detail)")
    }
    return AppleGatewayProcessDataOutput(
      stdoutData: stdoutData,
      stderrData: stderrData,
      terminationStatus: terminationStatus
    )
  }
  #endif

  private func collectPipeDataAfterTermination(
    _ drain: AppleGatewayPipeDrain,
    deadline: Date?,
    streamName: String
  ) throws -> Data {
    if let deadline {
      return try drain.waitForDataOrTimeout(deadline: deadline, streamName: streamName)
    }
    if let data = drain.waitForData(timeout: .now() + Self.pipeCloseGraceInterval) {
      return data
    }
    return drain.cancelAndReturnData()
  }
}

func waitForAppleGatewayProcess(
  _ process: Process,
  termination: DispatchSemaphore,
  until deadline: Date?
) -> Bool {
  guard process.isRunning else {
    return true
  }
  guard let deadline else {
    termination.wait()
    return true
  }
  let remaining = deadline.timeIntervalSinceNow
  guard remaining > 0 else {
    return false
  }
  return termination.wait(timeout: .now() + remaining) == .success
}

func terminateAppleGatewayProcess(_ process: Process, termination: DispatchSemaphore) {
  if process.isRunning {
    process.terminate()
  }
  guard termination.wait(timeout: .now() + 1) == .timedOut else {
    return
  }
  #if canImport(Darwin) || canImport(Glibc)
  if process.isRunning {
    _ = kill(process.processIdentifier, SIGKILL)
  }
  #endif
  _ = termination.wait(timeout: .now() + 1)
}

#if canImport(Darwin) || canImport(Glibc)
private func spawnProcessGroup(
  executablePath: String,
  arguments: [String],
  environment: [String: String],
  stdoutPipe: Pipe,
  stderrPipe: Pipe
) throws -> pid_t {
  #if canImport(Glibc)
  var fileActions = posix_spawn_file_actions_t()
  var attributes = posix_spawnattr_t()
  #else
  var fileActions: posix_spawn_file_actions_t?
  var attributes: posix_spawnattr_t?
  #endif
  posix_spawn_file_actions_init(&fileActions)
  posix_spawnattr_init(&attributes)
  defer {
    posix_spawn_file_actions_destroy(&fileActions)
    posix_spawnattr_destroy(&attributes)
  }
  try appleGatewaySpawnCheck(
    posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO),
    operation: "prepare stdout pipe"
  )
  try appleGatewaySpawnCheck(
    posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO),
    operation: "prepare stderr pipe"
  )
  try appleGatewaySpawnCheck(
    posix_spawn_file_actions_addclose(&fileActions, stdoutPipe.fileHandleForReading.fileDescriptor),
    operation: "close child stdout read pipe"
  )
  try appleGatewaySpawnCheck(
    posix_spawn_file_actions_addclose(&fileActions, stderrPipe.fileHandleForReading.fileDescriptor),
    operation: "close child stderr read pipe"
  )
  #if canImport(Darwin)
  let flags = Int16(POSIX_SPAWN_SETSID)
  try appleGatewaySpawnCheck(posix_spawnattr_setflags(&attributes, flags), operation: "set session flag")
  #else
  let flags = Int16(POSIX_SPAWN_SETPGROUP)
  try appleGatewaySpawnCheck(posix_spawnattr_setflags(&attributes, flags), operation: "set process-group flag")
  try appleGatewaySpawnCheck(posix_spawnattr_setpgroup(&attributes, 0), operation: "set process group")
  #endif

  var pid = pid_t()
  let argv = [executablePath] + arguments
  let envp = environment
    .sorted { $0.key < $1.key }
    .map { "\($0.key)=\($0.value)" }
  let result = executablePath.withCString { pathPointer in
    withAppleGatewayCStringArray(argv) { argvPointer in
      withAppleGatewayCStringArray(envp) { envpPointer in
        posix_spawn(&pid, pathPointer, &fileActions, &attributes, argvPointer, envpPointer)
      }
    }
  }
  if result != 0 {
    throw AdapterExecutionError(
      .providerError,
      "apple-gateway failed to start: \(String(cString: strerror(result)))"
    )
  }
  return pid
}

private func appleGatewaySpawnCheck(_ result: Int32, operation: String) throws {
  guard result == 0 else {
    throw AdapterExecutionError(
      .providerError,
      "apple-gateway failed to \(operation): \(String(cString: strerror(result)))"
    )
  }
}

private func withAppleGatewayCStringArray<T>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T) rethrows -> T {
  var cStrings = strings.map { strdup($0) }
  cStrings.append(nil)
  defer {
    for string in cStrings {
      free(string)
    }
  }
  return try cStrings.withUnsafeMutableBufferPointer { buffer in
    try body(buffer.baseAddress!)
  }
}

private func terminateAppleGatewayProcessGroup(pid: pid_t, termination: AppleGatewayProcessTermination) {
  let descendants = appleGatewayDescendantPIDs(of: pid)
  let processGroup = getpgid(pid)
  let groupToTerminate = processGroup > 0 ? processGroup : pid
  terminateAppleGatewayPIDs(descendants, signal: SIGTERM)
  _ = kill(-groupToTerminate, SIGTERM)
  terminateAppleGatewayPIDs(appleGatewayDescendantPIDs(of: pid) + descendants, signal: SIGKILL)
  _ = kill(-groupToTerminate, SIGKILL)
  guard !termination.wait(timeout: .now() + 1) else {
    return
  }
  _ = termination.wait(timeout: .now() + 1)
}

private func terminateAppleGatewayPIDs(_ pids: [pid_t], signal: Int32) {
  for pid in Set(pids) where pid > 0 {
    _ = kill(pid, signal)
  }
}

private func appleGatewayDescendantPIDs(of rootPID: pid_t) -> [pid_t] {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/ps")
  process.arguments = ["-axo", "pid=,ppid="]
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = Pipe()
  do {
    try process.run()
  } catch {
    return []
  }
  process.waitUntilExit()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  guard let output = String(data: data, encoding: .utf8) else {
    return []
  }
  var childrenByParent: [pid_t: [pid_t]] = [:]
  for line in output.split(whereSeparator: \.isNewline) {
    let fields = line.split(whereSeparator: \.isWhitespace)
    guard fields.count >= 2,
      let pid = pid_t(fields[0]),
      let parent = pid_t(fields[1])
    else {
      continue
    }
    childrenByParent[parent, default: []].append(pid)
  }
  var descendants: [pid_t] = []
  var stack = childrenByParent[rootPID] ?? []
  while let pid = stack.popLast() {
    descendants.append(pid)
    stack.append(contentsOf: childrenByParent[pid] ?? [])
  }
  return descendants
}

private final class AppleGatewayProcessTermination: @unchecked Sendable {
  private let completion = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private let pid: pid_t
  private var status: Int32?

  init(pid: pid_t) {
    self.pid = pid
    DispatchQueue.global(qos: .utility).async { [weak self] in
      self?.waitForExit()
    }
  }

  func wait(until deadline: Date?) -> Bool {
    guard let deadline else {
      completion.wait()
      return true
    }
    let remaining = deadline.timeIntervalSinceNow
    guard remaining > 0 else {
      return false
    }
    return wait(timeout: .now() + remaining)
  }

  func wait(timeout: DispatchTime) -> Bool {
    completion.wait(timeout: timeout) == .success
  }

  func exitStatus() -> Int32 {
    lock.lock()
    let rawStatus = status ?? 1
    lock.unlock()
    if rawStatus & 0x7f == 0 {
      return (rawStatus >> 8) & 0xff
    }
    return 128 + (rawStatus & 0x7f)
  }

  private func waitForExit() {
    var rawStatus: Int32 = 0
    while waitpid(pid, &rawStatus, 0) == -1 {
      guard errno == EINTR else {
        rawStatus = 1
        break
      }
    }
    lock.lock()
    status = rawStatus
    lock.unlock()
    completion.signal()
  }
}
#endif

final class AppleGatewayPipeDrain: @unchecked Sendable {
  private let handle: FileHandle
  private let lock = NSLock()
  private let completion = DispatchSemaphore(value: 0)
  private var data = Data()
  private var completed = false

  init(handle: FileHandle, label: String) {
    _ = label
    self.handle = handle
    handle.readabilityHandler = { [weak self] readableHandle in
      let chunk = readableHandle.availableData
      self?.record(chunk)
    }
  }

  func waitForData(timeout: DispatchTime? = nil) -> Data? {
    if let timeout {
      guard completion.wait(timeout: timeout) == .success else {
        return nil
      }
    } else {
      completion.wait()
    }
    lock.lock()
    defer { lock.unlock() }
    return data
  }

  func waitForDataOrTimeout(deadline: Date?, streamName: String) throws -> Data {
    if let deadline {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0,
        let data = waitForData(timeout: .now() + remaining)
      else {
        cancel()
        throw AdapterExecutionError(.timeout, "apple-gateway \(streamName) pipe did not close before deadline")
      }
      return data
    }
    return waitForData() ?? Data()
  }

  func cancel() {
    completeIfNeeded()
    handle.readabilityHandler = nil
    handle.closeFile()
  }

  func cancelAndReturnData() -> Data {
    cancel()
    return waitForData() ?? Data()
  }

  private func record(_ chunk: Data) {
    guard !chunk.isEmpty else {
      completeIfNeeded()
      return
    }
    lock.lock()
    if !completed {
      data.append(chunk)
    }
    lock.unlock()
  }

  private func completeIfNeeded() {
    lock.lock()
    let shouldSignal = !completed
    completed = true
    lock.unlock()
    if shouldSignal {
      handle.readabilityHandler = nil
      completion.signal()
    }
  }
}

struct AppleGatewayProcessOutput {
  var stdout: String
  var stderr: String
  var terminationStatus: Int32

  init(stdout: String, stderr: String, terminationStatus: Int32 = 0) {
    self.stdout = stdout
    self.stderr = stderr
    self.terminationStatus = terminationStatus
  }
}

struct AppleGatewayProcessDataOutput {
  var stdoutData: Data
  var stderrData: Data
  var terminationStatus: Int32
}

struct AppleGatewayGraphQLEnvelope {
  var data: JSONObject
  var errors: [String]
  var requestId: String?
  var extensions: JSONObject

  init(stdout: String, addonName: String) throws {
    guard let bytes = stdout.data(using: .utf8) else {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) stdout was not UTF-8")
    }
    let decoded: JSONValue
    do {
      decoded = try JSONDecoder().decode(JSONValue.self, from: bytes)
    } catch {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) stdout was not valid JSON: \(error.localizedDescription)")
    }
    guard case let .object(envelope) = decoded else {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) stdout must be a GraphQL JSON object")
    }
    self.errors = appleGatewayErrors(envelope["errors"])
    self.extensions = objectValue(envelope["extensions"]) ?? [:]
    self.requestId = nonEmptyString(extensions["requestId"])
    if !errors.isEmpty {
      self.data = [:]
      return
    }
    guard case let .object(data)? = envelope["data"] else {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) GraphQL data is missing")
    }
    self.data = data
  }

  func mutationField(_ name: String, addonName: String) throws -> JSONObject {
    guard case let .object(field)? = data[name] else {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) GraphQL data.\(name) is missing")
    }
    return field
  }
}

struct AppleGatewayResolvedBinary {
  var path: String
  var source: AppleGatewayBinarySource
}

enum AppleGatewayBinarySource: String {
  case config
  case environment
  case path
}

struct AppleGatewayBinaryResolver {
  private static let executableName = "apple-gateway"
  private static let executableEnvironmentName = "APPLE_GATEWAY_BIN"

  var addonName: String
  var config: JSONObject
  var environment: [String: String]

  func resolvedBinary() throws -> AppleGatewayResolvedBinary {
    if let configured = configuredBinaryPath() {
      guard let path = resolveExecutable(configured, searchPath: executableSearchPath(environment: environment)) else {
        throw AdapterExecutionError(.policyBlocked, "\(addonName) config.binaryPath is not executable: \(configured)")
      }
      return AppleGatewayResolvedBinary(path: path, source: .config)
    }
    if let envPath = environmentValue(Self.executableEnvironmentName, environment: environment) {
      guard let path = resolveExecutable(envPath, searchPath: executableSearchPath(environment: environment)) else {
        throw AdapterExecutionError(.policyBlocked, "\(Self.executableEnvironmentName) is not executable: \(envPath)")
      }
      return AppleGatewayResolvedBinary(path: path, source: .environment)
    }
    guard let path = resolveExecutable(Self.executableName, searchPath: executableSearchPath(environment: environment)) else {
      throw AdapterExecutionError(
        .policyBlocked,
        "\(addonName) requires apple-gateway; set config.binaryPath, \(Self.executableEnvironmentName), or PATH"
      )
    }
    return AppleGatewayResolvedBinary(path: path, source: .path)
  }

  private func configuredBinaryPath() -> String? {
    guard let configured = nonEmptyString(config["binaryPath"]) else {
      return nil
    }
    let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

struct AppleGatewayFileDownloader {
  private static let ownerOnlyDirectoryPermissions = 0o700
  private static let groupOrOtherPermissionBits = 0o077
  private static let privateRelativePrefixes = [
    ".riela-data/",
    ".riela-artifact/",
    ".riela-artifacts/",
    ".private/",
    "tmp/",
    "temp/"
  ]
  private static let privateAbsolutePrefixes = [
    "/tmp/",
    "/var/tmp/",
    "/var/folders/",
    "/private/tmp/",
    "/private/var/tmp/",
    "/private/var/folders/"
  ]
  private static let sharedTemporaryRoots = [
    "/tmp",
    "/var/tmp",
    "/private/tmp",
    "/private/var/tmp"
  ]
  private static let allowedSystemSymlinkComponents = [
    "/tmp",
    "/var"
  ]

  var runner: AppleGatewayProcessRunner
  var resolvedBinary: AppleGatewayResolvedBinary
  var currentDirectory: URL

  func download(keys: [String], outputRoot: String, deadline: Date?) throws -> [String: String] {
    let validatedOutputRoot = try validatedPrivateRuntimeDirectory(
      outputRoot,
      label: "RIELA_APPLE_NOTES_DOWNLOAD_ROOT"
    )
    guard !keys.isEmpty else {
      return [:]
    }
    let output = try runner.run(
      executablePath: resolvedBinary.path,
      arguments: ["file", "download"] + keys.flatMap { ["--key", $0] }
        + ["--output-dir", validatedOutputRoot.path],
      deadline: deadline
    )
    guard let data = output.stdout.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
    else {
      throw AdapterExecutionError(.providerError, "apple-gateway file download returned invalid JSON")
    }
    let downloaded = try downloadedLocalPaths(
      from: decoded,
      requestedKeys: keys,
      outputRoot: validatedOutputRoot
    )
    let missingKeys = keys.filter { downloaded[$0] == nil }
    guard missingKeys.isEmpty else {
      throw AdapterExecutionError(
        .providerError,
        "apple-gateway file download did not return a local path for requested key(s): \(missingKeys.joined(separator: ", "))"
      )
    }
    return downloaded
  }

  func validatedOutputRootPath(_ path: String, label: String) throws -> String {
    try validatedPrivateRuntimeDirectory(path, label: label).path
  }

  private func downloadedLocalPaths(
    from decoded: JSONValue,
    requestedKeys: [String],
    outputRoot: AppleGatewayValidatedOutputRoot
  ) throws -> [String: String] {
    let requested = Set(requestedKeys)
    let object = objectValue(decoded)
    let files = appleGatewayArray(object?["files"]) + appleGatewayArray(object?["downloads"])
    let candidates = files.isEmpty ? [decoded] : files
    var result: [String: String] = [:]
    for value in candidates {
      guard let file = objectValue(value),
        let localPath = nonEmptyString(file["localPath"]) ?? nonEmptyString(file["path"])
      else {
        continue
      }
      guard let key = nonEmptyString(file["downloadKey"]) ?? nonEmptyString(file["key"]) else {
        throw AdapterExecutionError(
          .providerError,
          "apple-gateway file download returned a local path without a downloadKey"
        )
      }
      guard requested.contains(key) else {
        continue
      }
      guard result[key] == nil else {
        throw AdapterExecutionError(
          .providerError,
          "apple-gateway file download returned multiple local paths for downloadKey: \(key)"
        )
      }
      result[key] = try validatedDownloadedLocalPath(localPath, outputRoot: outputRoot.realPath)
    }
    return result
  }

  private func validatedDownloadedLocalPath(_ path: String, outputRoot: String) throws -> String {
    let localURL = URL(fileURLWithPath: path, relativeTo: currentDirectory)
      .standardizedFileURL
    if isSymbolicLink(localURL) {
      throw AdapterExecutionError(
        .providerError,
        "apple-gateway file download returned a symbolic link local path: \(path)"
      )
    }
    let resolvedPath = localURL
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path
    let insideRoot = resolvedPath == outputRoot || resolvedPath.hasPrefix(outputRoot + "/")
    guard insideRoot else {
      throw AdapterExecutionError(
        .providerError,
        "apple-gateway file download returned a local path outside outputRoot: \(path)"
      )
    }
    guard FileManager.default.fileExists(atPath: resolvedPath) else {
      throw AdapterExecutionError(
        .providerError,
        "apple-gateway file download returned a local path that does not exist: \(path)"
      )
    }
    guard let type = try? FileManager.default.attributesOfItem(atPath: resolvedPath)[.type] as? FileAttributeType,
      type == .typeRegular
    else {
      throw AdapterExecutionError(
        .providerError,
        "apple-gateway file download returned a non-regular local path: \(path)"
      )
    }
    return resolvedPath
  }

  private func validatedPrivateRuntimeDirectory(
    _ path: String,
    label: String
  ) throws -> AppleGatewayValidatedOutputRoot {
    let url = URL(fileURLWithPath: path, relativeTo: currentDirectory).standardizedFileURL
    guard isPrivateRuntimePath(url.path) else {
      throw AdapterExecutionError(.policyBlocked, "\(label) must point to an ignored/private runtime path, got \(path)")
    }
    try validateNoExistingSymbolicLinkComponents(url, label: label, originalPath: path)
    let existedBefore = FileManager.default.fileExists(atPath: url.path)
    if existedBefore {
      if isSymbolicLink(url) {
        throw AdapterExecutionError(.policyBlocked, "\(label) must not be a symbolic link: \(path)")
      }
      try validateOwnerPrivateDirectory(url, label: label, originalPath: path)
    }
    do {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: Self.ownerOnlyDirectoryPermissions]
      )
    } catch {
      throw AdapterExecutionError(.policyBlocked, "\(label) could not be created: \(path)")
    }
    if isSymbolicLink(url) {
      throw AdapterExecutionError(.policyBlocked, "\(label) must not be a symbolic link: \(path)")
    }
    let realURL = url.resolvingSymlinksInPath().standardizedFileURL
    guard isPrivateRuntimePath(realURL.path) else {
      throw AdapterExecutionError(.policyBlocked, "\(label) resolves outside ignored/private runtime paths: \(path)")
    }
    if !existedBefore {
      do {
        try FileManager.default.setAttributes(
          [.posixPermissions: Self.ownerOnlyDirectoryPermissions],
          ofItemAtPath: realURL.path
        )
      } catch {
        throw AdapterExecutionError(.policyBlocked, "\(label) could not be made owner-private: \(path)")
      }
    }
    try validateOwnerPrivateDirectory(realURL, label: label, originalPath: path)
    try validateSharedTemporaryBoundary(realURL, label: label, originalPath: path)
    return AppleGatewayValidatedOutputRoot(path: url.path, realPath: realURL.path)
  }

  private func validateNoExistingSymbolicLinkComponents(
    _ url: URL,
    label: String,
    originalPath: String
  ) throws {
    var currentURL = URL(fileURLWithPath: "/", isDirectory: true)
    for component in url.pathComponents.dropFirst() {
      currentURL.appendPathComponent(component, isDirectory: true)
      guard FileManager.default.fileExists(atPath: currentURL.path) else {
        return
      }
      if isSymbolicLink(currentURL), !Self.allowedSystemSymlinkComponents.contains(currentURL.path) {
        throw AdapterExecutionError(
          .policyBlocked,
          "\(label) must not contain a symbolic link component: \(originalPath)"
        )
      }
    }
  }

  private func validateOwnerPrivateDirectory(
    _ url: URL,
    label: String,
    originalPath: String
  ) throws {
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    } catch {
      throw AdapterExecutionError(.policyBlocked, "\(label) could not be inspected: \(originalPath)")
    }
    guard let type = attributes[.type] as? FileAttributeType,
      type == .typeDirectory
    else {
      throw AdapterExecutionError(.policyBlocked, "\(label) must point to a directory: \(originalPath)")
    }
    #if canImport(Darwin) || canImport(Glibc)
    if let owner = attributes[.ownerAccountID] as? NSNumber,
      owner.uint32Value != getuid() {
      throw AdapterExecutionError(.policyBlocked, "\(label) must be owned by the current user: \(originalPath)")
    }
    #endif
    guard let permissions = attributes[.posixPermissions] as? NSNumber,
      permissions.intValue & Self.groupOrOtherPermissionBits == 0
    else {
      throw AdapterExecutionError(
        .policyBlocked,
        "\(label) must be owner-private with no group/other permissions: \(originalPath)"
      )
    }
  }

  private func validateSharedTemporaryBoundary(
    _ realURL: URL,
    label: String,
    originalPath: String
  ) throws {
    let realPath = realURL.path
    guard let sharedRoot = Self.sharedTemporaryRoots.first(where: { sharedRoot in
      realPath == sharedRoot || realPath.hasPrefix(sharedRoot + "/")
    }) else {
      return
    }
    let suffix = realPath.dropFirst(sharedRoot.count).drop(while: { $0 == "/" })
    guard let firstComponent = suffix.split(separator: "/").first else {
      throw AdapterExecutionError(.policyBlocked, "\(label) must not use a shared temporary root directly: \(originalPath)")
    }
    let boundaryURL = URL(fileURLWithPath: sharedRoot)
      .appendingPathComponent(String(firstComponent), isDirectory: true)
      .standardizedFileURL
    try validateOwnerPrivateDirectory(boundaryURL, label: label, originalPath: originalPath)
  }

  private func isPrivateRuntimePath(_ path: String) -> Bool {
    let cwd = currentDirectory.resolvingSymlinksInPath().standardizedFileURL.path
    let relative = path.hasPrefix(cwd + "/") ? String(path.dropFirst(cwd.count + 1)) : ""
    return Self.privateRelativePrefixes.contains { relative.hasPrefix($0) }
      || Self.privateAbsolutePrefixes.contains { path.hasPrefix($0) }
  }

  private func isSymbolicLink(_ url: URL) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
  }
}

private struct AppleGatewayValidatedOutputRoot {
  var path: String
  var realPath: String
}

func appleGatewayArray(_ value: JSONValue?) -> [JSONValue] {
  guard case let .array(values)? = value else {
    return []
  }
  return values
}

func appleGatewayErrors(_ value: JSONValue?) -> [String] {
  appleGatewayArray(value).compactMap { error in
    guard case let .object(object) = error else {
      let text = error.compactJSONStringOrEmpty()
      return text.isEmpty ? nil : text
    }
    var parts: [String] = []
    if let message = nonEmptyString(object["message"]) {
      parts.append(message)
    }
    if let extensions = object["extensions"]?.compactJSONStringOrEmpty(), !extensions.isEmpty {
      parts.append("extensions=\(extensions)")
    }
    let text = parts.isEmpty ? error.compactJSONStringOrEmpty() : parts.joined(separator: " ")
    return text.isEmpty ? nil : text
  }
}

func appleGatewayGraphQLString(_ value: String) -> String {
  let data = (try? JSONEncoder().encode(value)) ?? Data("\"\(value)\"".utf8)
  return String(data: data, encoding: .utf8) ?? "\"\""
}

func appleGatewayCompactText(_ value: String, maxLength: Int = 600) -> String {
  let compact = value
    .split(whereSeparator: \.isNewline)
    .joined(separator: " ")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard compact.count > maxLength else {
    return compact
  }
  let endIndex = compact.index(compact.startIndex, offsetBy: maxLength)
  return String(compact[..<endIndex]) + "..."
}

func appleGatewayRequiredArray(_ value: JSONValue?, field: String) throws -> [JSONValue] {
  guard case let .array(values)? = value else {
    throw AdapterExecutionError(.invalidOutput, "\(field) must be an array")
  }
  return values
}

func appleGatewayRequiredObject(_ value: JSONValue?, field: String) throws -> JSONObject {
  guard case let .object(object)? = value else {
    throw AdapterExecutionError(.invalidOutput, "\(field) must be an object")
  }
  return object
}

func appleGatewayRequiredNumber(_ value: JSONValue?, field: String) throws -> JSONValue {
  guard let value, value.asDouble != nil else {
    throw AdapterExecutionError(.invalidOutput, "\(field) must be numeric")
  }
  return value
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
