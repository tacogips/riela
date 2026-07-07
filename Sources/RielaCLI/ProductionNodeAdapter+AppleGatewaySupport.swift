import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct AppleGatewayProcessRunner {
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

  func run(executablePath: String, arguments: [String], deadline: Date?) throws -> AppleGatewayProcessOutput {
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
      _ = stdoutDrain.waitForData()
      _ = stderrDrain.waitForData()
      throw AdapterExecutionError(.timeout, "apple-gateway exceeded deadline and was terminated")
    }
    process.terminationHandler = nil
    let stdout = String(data: stdoutDrain.waitForData(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrDrain.waitForData(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      let detail = appleGatewayCompactText(stderr.isEmpty ? stdout : stderr)
      throw AdapterExecutionError(.providerError, "apple-gateway failed with exit code \(process.terminationStatus): \(detail)")
    }
    return AppleGatewayProcessOutput(stdout: stdout, stderr: stderr)
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
  termination.wait()
}

final class AppleGatewayPipeDrain: @unchecked Sendable {
  private let group = DispatchGroup()
  private let lock = NSLock()
  private var data = Data()

  init(handle: FileHandle, label: String) {
    group.enter()
    DispatchQueue(label: label).async {
      let drained = handle.readDataToEndOfFile()
      self.lock.lock()
      self.data = drained
      self.lock.unlock()
      self.group.leave()
    }
  }

  func waitForData() -> Data {
    group.wait()
    lock.lock()
    defer { lock.unlock() }
    return data
  }
}

struct AppleGatewayProcessOutput {
  var stdout: String
  var stderr: String
}

struct AppleGatewayGraphQLEnvelope {
  var data: JSONObject
  var errors: [String]
  var requestId: String?

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
    self.requestId = objectValue(envelope["extensions"]).flatMap { nonEmptyString($0["requestId"]) }
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
    "/var/folders/"
  ]

  var runner: AppleGatewayProcessRunner
  var resolvedBinary: AppleGatewayResolvedBinary
  var currentDirectory: URL

  func download(keys: [String], outputRoot: String, deadline: Date?) throws -> [String: String] {
    try assertPrivateRuntimeDirectory(outputRoot, label: "RIELA_APPLE_NOTES_DOWNLOAD_ROOT")
    guard !keys.isEmpty else {
      return [:]
    }
    let output = try runner.run(
      executablePath: resolvedBinary.path,
      arguments: ["file", "download"] + keys.flatMap { ["--key", $0] } + ["--output-dir", outputRoot],
      deadline: deadline
    )
    guard let data = output.stdout.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
    else {
      throw AdapterExecutionError(.providerError, "apple-gateway file download returned invalid JSON")
    }
    let downloaded = downloadedLocalPaths(from: decoded, requestedKeys: keys)
    let missingKeys = keys.filter { downloaded[$0] == nil }
    guard missingKeys.isEmpty else {
      throw AdapterExecutionError(
        .providerError,
        "apple-gateway file download did not return a local path for requested key(s): \(missingKeys.joined(separator: ", "))"
      )
    }
    return downloaded
  }

  private func downloadedLocalPaths(from decoded: JSONValue, requestedKeys: [String]) -> [String: String] {
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
      let key = nonEmptyString(file["downloadKey"]) ?? nonEmptyString(file["key"])
      if let key, requested.contains(key) {
        result[key] = localPath
      }
    }
    return result
  }

  private func assertPrivateRuntimeDirectory(_ path: String, label: String) throws {
    let resolved = URL(fileURLWithPath: path, relativeTo: currentDirectory).standardizedFileURL.path
    let cwd = currentDirectory.standardizedFileURL.path
    let relative = resolved.hasPrefix(cwd + "/") ? String(resolved.dropFirst(cwd.count + 1)) : ""
    let allowed = Self.privateRelativePrefixes.contains { relative.hasPrefix($0) }
      || Self.privateAbsolutePrefixes.contains { resolved.hasPrefix($0) }
    guard allowed else {
      throw AdapterExecutionError(.policyBlocked, "\(label) must point to an ignored/private runtime path, got \(path)")
    }
  }
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
