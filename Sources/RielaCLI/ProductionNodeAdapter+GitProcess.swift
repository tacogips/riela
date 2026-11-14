import Foundation
#if canImport(Darwin)
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif
#else
import Glibc
#endif
import RielaCore

struct GitCommandResult: Equatable, Sendable {
  var exitCode: Int32
  var output: String
}

struct GitCommandInvocation: Sendable {
  var executableURL: URL
  var arguments: [String]
  var workingDirectory: URL
  var environment: [String: String]
  var standardInput: Data?
  var standardInputFileDescriptor: Int32?
  var deadline: Date?

  init(
    executableURL: URL,
    arguments: [String],
    workingDirectory: URL,
    environment: [String: String],
    standardInput: Data?,
    standardInputFileDescriptor: Int32? = nil,
    deadline: Date? = nil
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.standardInput = standardInput
    self.standardInputFileDescriptor = standardInputFileDescriptor
    self.deadline = deadline
  }
}

enum GitCommandRunnerError: Error {
  case invalidUTF8Output
  case outputTooLarge
  case deadlineExceeded
  case processLaunchFailed
}

protocol GitCommandRunning: Sendable {
  func run(_ invocation: GitCommandInvocation) throws -> GitCommandResult
}

struct FoundationGitCommandRunner: GitCommandRunning {
  private static let maxOutputBytes = 1_048_576
  private static let pollIntervalMilliseconds: Int32 = 25

  func run(_ invocation: GitCommandInvocation) throws -> GitCommandResult {
    let outputPipe = Pipe()
    let inputPipe = invocation.standardInput == nil ? nil : Pipe()
    let processID = try spawnGitProcess(
      invocation,
      outputPipe: outputPipe,
      inputPipe: inputPipe
    )
    try? outputPipe.fileHandleForWriting.close()
    if let inputPipe {
      try? inputPipe.fileHandleForReading.close()
      if let standardInput = invocation.standardInput {
        try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
      }
      try inputPipe.fileHandleForWriting.close()
    }

    let outputHandle = outputPipe.fileHandleForReading
    defer { try? outputHandle.close() }
    let outputDescriptor = outputHandle.fileDescriptor
    let existingFlags = fcntl(outputDescriptor, F_GETFL)
    guard existingFlags >= 0,
          fcntl(outputDescriptor, F_SETFL, existingFlags | O_NONBLOCK) == 0 else {
      terminateGitProcessGroup(processID)
      _ = waitForGitProcess(processID)
      throw GitCommandRunnerError.processLaunchFailed
    }

    var output = Data()
    var waitStatus: Int32?
    var reachedEndOfOutput = false
    while waitStatus == nil || !reachedEndOfOutput {
      if let deadline = invocation.deadline {
        let remaining = deadline.timeIntervalSinceNow
        if !remaining.isFinite || remaining <= 0 {
          terminateGitProcessGroup(processID)
          _ = waitForGitProcess(processID)
          throw GitCommandRunnerError.deadlineExceeded
        }
      }
      if waitStatus == nil {
        waitStatus = nonblockingGitWaitStatus(processID)
      }
      reachedEndOfOutput = try readAvailableGitOutput(
        from: outputDescriptor,
        into: &output,
        maximumBytes: Self.maxOutputBytes
      )
      if output.count > Self.maxOutputBytes {
        terminateGitProcessGroup(processID)
        _ = waitForGitProcess(processID)
        throw GitCommandRunnerError.outputTooLarge
      }
      if waitStatus != nil, reachedEndOfOutput {
        break
      }
      var descriptor = pollfd(fd: outputDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
      let timeout = pollTimeoutMilliseconds(
        deadline: invocation.deadline,
        maximum: Self.pollIntervalMilliseconds
      )
      _ = poll(&descriptor, 1, timeout)
    }

    let status = waitStatus ?? waitForGitProcess(processID)
    guard let renderedOutput = String(data: output, encoding: .utf8) else {
      throw GitCommandRunnerError.invalidUTF8Output
    }
    return GitCommandResult(exitCode: gitTerminationStatus(status), output: renderedOutput)
  }
}

enum GitCommandRuntimeContext {
  @TaskLocal static var deadline: Date?
}

private func spawnGitProcess(
  _ invocation: GitCommandInvocation,
  outputPipe: Pipe,
  inputPipe: Pipe?
) throws -> pid_t {
  #if canImport(Glibc)
  var fileActions = posix_spawn_file_actions_t()
  var attributes = posix_spawnattr_t()
  #else
  var fileActions: posix_spawn_file_actions_t?
  var attributes: posix_spawnattr_t?
  #endif
  guard posix_spawn_file_actions_init(&fileActions) == 0,
        posix_spawnattr_init(&attributes) == 0 else {
    throw GitCommandRunnerError.processLaunchFailed
  }
  defer {
    posix_spawn_file_actions_destroy(&fileActions)
    posix_spawnattr_destroy(&attributes)
  }

  let outputRead = outputPipe.fileHandleForReading.fileDescriptor
  let outputWrite = outputPipe.fileHandleForWriting.fileDescriptor
  try checkGitSpawn(posix_spawn_file_actions_adddup2(&fileActions, outputWrite, STDOUT_FILENO))
  try checkGitSpawn(posix_spawn_file_actions_adddup2(&fileActions, outputWrite, STDERR_FILENO))
  try checkGitSpawn(posix_spawn_file_actions_addclose(&fileActions, outputRead))
  try checkGitSpawn(posix_spawn_file_actions_addclose(&fileActions, outputWrite))
  if let descriptor = invocation.standardInputFileDescriptor {
    try checkGitSpawn(posix_spawn_file_actions_adddup2(&fileActions, descriptor, STDIN_FILENO))
    if descriptor != STDIN_FILENO {
      try checkGitSpawn(posix_spawn_file_actions_addclose(&fileActions, descriptor))
    }
  } else if let inputPipe {
    let inputRead = inputPipe.fileHandleForReading.fileDescriptor
    let inputWrite = inputPipe.fileHandleForWriting.fileDescriptor
    try checkGitSpawn(posix_spawn_file_actions_adddup2(&fileActions, inputRead, STDIN_FILENO))
    try checkGitSpawn(posix_spawn_file_actions_addclose(&fileActions, inputRead))
    try checkGitSpawn(posix_spawn_file_actions_addclose(&fileActions, inputWrite))
  } else {
    try checkGitSpawn(posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
  }
  try invocation.workingDirectory.path.withCString { path in
    try checkGitSpawn(posix_spawn_file_actions_addchdir_np(&fileActions, path))
  }
  #if canImport(Darwin)
  let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
  #else
  let flags = Int16(POSIX_SPAWN_SETPGROUP)
  #endif
  try checkGitSpawn(posix_spawnattr_setflags(&attributes, flags))
  try checkGitSpawn(posix_spawnattr_setpgroup(&attributes, 0))

  let arguments = GitCStringArray([invocation.executableURL.path] + invocation.arguments)
  let environment = GitCStringArray(
    invocation.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
  )
  var processID = pid_t()
  let result = invocation.executableURL.path.withCString { executablePath in
    arguments.withUnsafeMutableBufferPointer { argumentPointer in
      environment.withUnsafeMutableBufferPointer { environmentPointer in
        posix_spawn(
          &processID,
          executablePath,
          &fileActions,
          &attributes,
          argumentPointer,
          environmentPointer
        )
      }
    }
  }
  try checkGitSpawn(result)
  return processID
}

private func checkGitSpawn(_ result: Int32) throws {
  guard result == 0 else {
    throw GitCommandRunnerError.processLaunchFailed
  }
}

private func readAvailableGitOutput(
  from descriptor: Int32,
  into output: inout Data,
  maximumBytes: Int
) throws -> Bool {
  var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
  while true {
    let bytesRead = read(descriptor, &buffer, buffer.count)
    if bytesRead > 0 {
      let retainedCount = min(bytesRead, maximumBytes + 1 - output.count)
      if retainedCount > 0 {
        output.append(buffer, count: retainedCount)
      }
      if output.count > maximumBytes {
        return false
      }
      continue
    }
    if bytesRead == 0 {
      return true
    }
    if errno == EAGAIN || errno == EWOULDBLOCK {
      return false
    }
    if errno == EINTR {
      continue
    }
    throw GitCommandRunnerError.processLaunchFailed
  }
}

private func nonblockingGitWaitStatus(_ processID: pid_t) -> Int32? {
  var status = Int32()
  let result = waitpid(processID, &status, WNOHANG)
  return result == processID ? status : nil
}

private func waitForGitProcess(_ processID: pid_t) -> Int32 {
  var status = Int32()
  while waitpid(processID, &status, 0) < 0, errno == EINTR {}
  return status
}

private func terminateGitProcessGroup(_ processID: pid_t) {
  _ = kill(-processID, SIGTERM)
  let deadline = Date().addingTimeInterval(0.25)
  while kill(-processID, 0) == 0, Date() < deadline {
    Thread.sleep(forTimeInterval: 0.01)
  }
  if kill(-processID, 0) == 0 || errno == EPERM {
    _ = kill(-processID, SIGKILL)
  }
}

private func pollTimeoutMilliseconds(deadline: Date?, maximum: Int32) -> Int32 {
  guard let deadline else {
    return maximum
  }
  let remainingMilliseconds = deadline.timeIntervalSinceNow * 1_000
  guard remainingMilliseconds.isFinite, remainingMilliseconds > 0 else {
    return 0
  }
  let clampedMilliseconds = min(remainingMilliseconds.rounded(.up), Double(maximum))
  return Int32(clampedMilliseconds)
}

private func gitTerminationStatus(_ waitStatus: Int32) -> Int32 {
  if waitStatus & 0x7f == 0 {
    return (waitStatus >> 8) & 0xff
  }
  return -(waitStatus & 0x7f)
}

private final class GitCStringArray {
  private let values: [UnsafeMutablePointer<CChar>?]

  init(_ strings: [String]) {
    values = strings.map { strdup($0) } + [nil]
  }

  deinit {
    values.forEach { pointer in
      if let pointer {
        free(pointer)
      }
    }
  }

  // Non-optional pointer: glibc's posix_spawn takes non-optional argv/envp
  // (Darwin's optional parameters accept it either way), and the array always
  // holds at least its nil terminator.
  func withUnsafeMutableBufferPointer<Result>(
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
  ) -> Result {
    var mutableValues = values
    return mutableValues.withUnsafeMutableBufferPointer { buffer in
      body(buffer.baseAddress!)
    }
  }
}

struct GitExecutablePolicy: Sendable {
  static let versionOneURL = URL(fileURLWithPath: "/usr/bin/git")
  static let macOSCredentialHelperURL = URL(fileURLWithPath: "/usr/bin/git-credential-osxkeychain")
  static let sshURL = URL(fileURLWithPath: "/usr/bin/ssh")

  func validateGit(at selectedURL: URL, repositoryRoot: URL) throws -> URL {
    guard selectedURL.standardizedFileURL.path == Self.versionOneURL.path else {
      throw policyError("git executable is outside the version 1 system allowlist")
    }
    return try validateTrustedExecutable(at: selectedURL, repositoryRoot: repositoryRoot)
  }

  func validateTrustedExecutable(at selectedURL: URL, repositoryRoot: URL) throws -> URL {
    let canonical = selectedURL.resolvingSymlinksInPath().standardizedFileURL
    guard !isURL(canonical, inside: repositoryRoot) else {
      throw policyError("trusted executable resolves inside the repository")
    }
    try validateTrustedPath(canonical, requiresExecutableFile: true)
    return canonical
  }

  func validateTrustedDirectory(at selectedURL: URL, repositoryRoot: URL) throws -> URL {
    let canonical = selectedURL.resolvingSymlinksInPath().standardizedFileURL
    guard !isURL(canonical, inside: repositoryRoot) else {
      throw policyError("trusted helper root resolves inside the repository")
    }
    try validateTrustedPath(canonical, requiresExecutableFile: false)
    return canonical
  }

  private func validateTrustedPath(_ url: URL, requiresExecutableFile: Bool) throws {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
    if requiresExecutableFile {
      guard values.isRegularFile == true else {
        throw policyError("trusted executable is not a regular file")
      }
    } else if values.isDirectory != true {
      throw policyError("trusted helper root is not a directory")
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
          let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue else {
      throw policyError("trusted path ownership could not be verified")
    }
    if requiresExecutableFile {
      guard permissions & 0o111 != 0, permissions & 0o022 == 0 else {
        throw policyError("trusted executable permissions are unsafe")
      }
    }

    var current = requiresExecutableFile ? url.deletingLastPathComponent() : url
    while true {
      let parentAttributes = try FileManager.default.attributesOfItem(atPath: current.path)
      guard (parentAttributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
            let parentPermissions = (parentAttributes[.posixPermissions] as? NSNumber)?.intValue,
            let groupID = (parentAttributes[.groupOwnerAccountID] as? NSNumber)?.intValue else {
        throw policyError("trusted path parent ownership could not be verified")
      }
      guard parentPermissions & 0o002 == 0,
            parentPermissions & 0o020 == 0 || groupID == 0 || groupID == 80 else {
        throw policyError("trusted path parent permissions are unsafe")
      }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path {
        break
      }
      current = parent
    }
  }
}

extension BuiltinWorkflowAddonResolver {
  func validateProductionGitExecutable(repositoryRoot: URL) throws -> URL {
    try gitExecutablePolicy.validateGit(at: gitExecutableURL, repositoryRoot: repositoryRoot)
  }

  func runGit(
    _ arguments: [String],
    environment additionalEnvironment: [String: String] = [:],
    standardInput: Data? = nil,
    standardInputFileDescriptor: Int32? = nil,
    executableURL: URL? = nil,
    workingDirectory selectedWorkingDirectory: URL? = nil
  ) throws -> GitCommandResult {
    let result = try runGitResult(
      arguments,
      environment: additionalEnvironment,
      standardInput: standardInput,
      standardInputFileDescriptor: standardInputFileDescriptor,
      executableURL: executableURL,
      workingDirectory: selectedWorkingDirectory
    )
    guard result.exitCode == 0 else {
      throw AdapterExecutionError(
        .providerError,
        "git command failed with exit code \(result.exitCode)",
        isRetryable: true
      )
    }
    return result
  }

  func runGitResult(
    _ arguments: [String],
    environment additionalEnvironment: [String: String] = [:],
    standardInput: Data? = nil,
    standardInputFileDescriptor: Int32? = nil,
    executableURL: URL? = nil,
    workingDirectory selectedWorkingDirectory: URL? = nil
  ) throws -> GitCommandResult {
    let safetyArguments = [
      "--no-replace-objects",
      "-c", "core.hooksPath=\(gitFinalizationStore.hooksDirectory.path)",
      "-c", "core.fsmonitor=false",
      "-c", "commit.gpgSign=false",
      "-c", "tag.gpgSign=false",
      "-c", "push.gpgSign=false",
      "-c", "credential.interactive=never",
      "-c", "http.proxy=",
      "-c", "core.gitProxy=",
      "-c", "http.extraHeader=",
      "-c", "http.cookieFile=",
      "-c", "http.sslKey=",
      "-c", "core.pager=cat",
      "-c", "pager.branch=false"
    ]
    do {
      return try gitCommandRunner.run(GitCommandInvocation(
        executableURL: executableURL ?? gitExecutableURL,
        arguments: safetyArguments + arguments,
        workingDirectory: selectedWorkingDirectory ?? workingDirectory,
        environment: minimalGitEnvironment(additional: additionalEnvironment),
        standardInput: standardInput,
        standardInputFileDescriptor: standardInputFileDescriptor,
        deadline: GitCommandRuntimeContext.deadline
      ))
    } catch GitCommandRunnerError.deadlineExceeded {
      throw AdapterExecutionError(.timeout, "git command exceeded its workflow deadline and was terminated")
    } catch let adapterError as AdapterExecutionError {
      throw adapterError
    } catch {
      throw AdapterExecutionError(.providerError, "unable to execute git", isRetryable: true)
    }
  }

  private func minimalGitEnvironment(additional: [String: String]) -> [String: String] {
    let preservedKeys = ["HOME", "LANG", "LC_ALL", "LC_CTYPE", "TZ", "SSH_AUTH_SOCK"]
    var result = environment.filter { preservedKeys.contains($0.key) }
    result["GIT_TERMINAL_PROMPT"] = "0"
    result["GIT_PAGER"] = "cat"
    result["PAGER"] = "cat"
    result["GIT_LITERAL_PATHSPECS"] = "1"
    result["GIT_CONFIG_COUNT"] = nil
    result["GIT_CONFIG_KEY_0"] = nil
    result["GIT_CONFIG_VALUE_0"] = nil
    for (key, value) in additional {
      result[key] = value
    }
    return result
  }
}

func policyError(_ message: String, retryable: Bool = false) -> AdapterExecutionError {
  AdapterExecutionError(.policyBlocked, message, isRetryable: retryable)
}

func isURL(_ url: URL, inside directory: URL) -> Bool {
  let path = url.standardizedFileURL.path
  let directoryPath = directory.standardizedFileURL.path
  return path == directoryPath || path.hasPrefix(directoryPath + "/")
}
