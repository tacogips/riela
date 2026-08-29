#if canImport(AppleGatewayCore)
import AppleGatewayCore
#endif
import Foundation
import RielaAddonSupport
import RielaCore
#if canImport(Darwin)
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif
#elseif canImport(Glibc)
import Glibc
#endif
/// Calls apple-gateway, which riela links as a library and runs inside its own
/// process. macOS attaches Apple Events / Calendars / Reminders / Contacts
/// permission grants to the calling executable, so those grants now belong to
/// `riela` (bundle id `me.tacogips.riela`, usage strings in
/// `Resources/RielaInfo.plist`) rather than to a separate `apple-gateway`
/// binary.
/// Runs one apple-gateway invocation. Production leaves this nil and the
/// linked gateway answers; tests substitute a stand-in so add-on policy is
/// covered without touching the machine's real Notes, Mail, or Calendars.
typealias AppleGatewayRunner = @Sendable (
  _ arguments: [String],
  _ environment: [String: String],
  _ deadline: Date?
) throws -> AppleGatewayProcessOutput

struct AppleGatewayInvoker {
  /// Ambient process variables the gateway is allowed to see. Secrets are
  /// never forwarded implicitly; only names an add-on's contract declares are
  /// injected on top of this list, exactly as when the gateway ran as a child
  /// process.
  static let environmentAllowlist = [
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
  /// Explicitly resolved add-on environment bindings injected on top of the
  /// allowlist. Callers must only pass values the add-on contract declares.
  var extraEnvironment: [String: String] = [:]
  /// Test seam; nil in production.
  var runnerOverride: AppleGatewayRunner?

  /// Runs one gateway command.
  ///
  /// `deadline` is checked before the call: the gateway is a linked library
  /// now, so unlike the child process it replaced, a call already under way
  /// cannot be killed. A step whose deadline passes mid-call fails when the
  /// call returns rather than at the deadline itself.
  func run(
    arguments: [String],
    deadline: Date?,
    allowNonzeroExit: Bool = false
  ) throws -> AppleGatewayProcessOutput {
    if let deadline, deadline.timeIntervalSinceNow <= 0 {
      throw AdapterExecutionError(.timeout, "apple-gateway exceeded deadline before it was called")
    }
    if let runnerOverride {
      let output = try runnerOverride(arguments, gatewayEnvironment(), deadline)
      guard allowNonzeroExit || output.terminationStatus == 0 else {
        throw AdapterExecutionError(
          .providerError,
          "apple-gateway failed with exit code \(output.terminationStatus): \(appleGatewayCompactText(output.stderr.isEmpty ? output.stdout : output.stderr))"
        )
      }
      return output
    }
    #if canImport(AppleGatewayCore)
    let result: AppleGatewayCommandResult
    do {
      result = try AppleGatewayCommand(
        arguments: arguments,
        environment: gatewayEnvironment(),
        role: .full
      ).runResult()
    } catch let error as AppleGatewayCommand.Error {
      throw AdapterExecutionError(.invalidInput, "apple-gateway rejected the request: \(error)")
    } catch {
      throw AdapterExecutionError(.providerError, "apple-gateway failed: \(error)")
    }
    guard allowNonzeroExit || result.exitCode == 0 else {
      throw AdapterExecutionError(
        .providerError,
        "apple-gateway failed with exit code \(result.exitCode): \(appleGatewayCompactText(result.output))"
      )
    }
    return AppleGatewayProcessOutput(
      stdout: result.output,
      stderr: "",
      terminationStatus: result.exitCode
    )
    #else
    throw AdapterExecutionError(
      .policyBlocked,
      "apple-gateway add-ons require macOS"
    )
    #endif
  }

  /// The same call as `run`, handing back the gateway's stdout bytes for
  /// callers that write them straight to a file. The gateway's commands all
  /// return text, so this is the UTF-8 encoding of the same output the CLI
  /// would have printed.
  func runData(
    arguments: [String],
    deadline: Date?,
    allowNonzeroExit: Bool = false
  ) throws -> AppleGatewayProcessDataOutput {
    let output = try run(arguments: arguments, deadline: deadline, allowNonzeroExit: allowNonzeroExit)
    return AppleGatewayProcessDataOutput(
      stdoutData: Data(output.stdout.utf8),
      stderrData: Data(output.stderr.utf8),
      terminationStatus: output.terminationStatus
    )
  }

  private func gatewayEnvironment() -> [String: String] {
    var environment: [String: String] = [:]
    for name in Self.environmentAllowlist {
      guard let value = runtimeEnvironment[name], !value.isEmpty else { continue }
      environment[name] = value
    }
    for (name, value) in extraEnvironment where !value.isEmpty {
      environment[name] = value
    }
    return environment
  }
}

/// The environment a gateway is allowed to observe: the ambient allowlist plus
/// exactly the bindings an add-on's contract declared. Shared by every add-on
/// that calls a gateway linked as a library, so hosting a gateway in this
/// process cannot widen what it can read compared with running it as a child.
func sanitizedGatewayEnvironment(
  runtimeEnvironment: [String: String],
  bindings: [String: String]
) -> [String: String] {
  var environment: [String: String] = [:]
  for name in AppleGatewayInvoker.environmentAllowlist {
    guard let value = runtimeEnvironment[name], !value.isEmpty else { continue }
    environment[name] = value
  }
  for (name, value) in bindings where !value.isEmpty {
    environment[name] = value
  }
  return environment
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

  var runner: AppleGatewayInvoker
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

/// `config.binaryPath` and `APPLE_GATEWAY_BIN` named the executable riela used
/// to spawn. The gateway is linked in now, so a leftover setting would point at
/// a binary nothing runs; refusing it beats ignoring it.
func refuseAppleGatewayBinaryPath(_ input: WorkflowAddonExecutionInput) throws {
  guard (input.addon.config ?? [:])["binaryPath"] == nil else {
    throw AdapterExecutionError(
      .policyBlocked,
      "\(input.addon.name) config.binaryPath is not supported; apple-gateway runs in-process, remove it"
    )
  }
}
