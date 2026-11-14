import Foundation
import RielaAdapters
import RielaAddons
import RielaCore

struct ContainerAddonRegistration: Equatable, Sendable {
  var packageName: String
  var addonName: String
  var version: String
  var packageRoot: URL
  var addonRoot: URL
  var entrypoint: String?
  var containerfilePath: String?
  var image: String?
  var imageDigest: String?
  var contentDigest: String
  var capabilities: [WorkflowAddonCapability]
}

struct ContainerWorkflowAddonResolver: WorkflowAddonResolving {
  var registrations: [ContainerAddonRegistration]
  var workingDirectory: URL
  var environment: [String: String]
  var runner: any LocalAgentProcessRunning

  init(
    registrations: [ContainerAddonRegistration],
    workingDirectory: URL,
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment(),
    runner: any LocalAgentProcessRunning = FoundationLocalAgentProcessRunner()
  ) {
    self.registrations = registrations
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.runner = runner
  }

  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    let registration = try selectedRegistration(for: input.addon)
    let driver = try selectedRuntimeDriver()
    let image = try await imageReference(for: registration, driver: driver, deadline: context.deadline)

    let artifactRoot = artifactRootURL()
    try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
    let addonInput = try addonExecutionInput(input, registration: registration)
    let sandboxPolicy = try ContainerAddonSandboxPolicy(
      registration: registration,
      workingDirectory: workingDirectory,
      artifactRoot: artifactRoot,
      addonInput: addonInput
    )
    let stdin = try jsonLine(addonInput)
    let runConfiguration = processConfiguration(
      driver: driver,
      arguments: driver.runArguments(image: image, options: ContainerRuntimeRunOptions(
        environment: resolvedContainerEnvironment(registration: registration, artifactRoot: artifactRoot),
        mounts: sandboxPolicy.mounts,
        entrypoint: registration.entrypoint,
        workingDirectory: workingDirectory.standardizedFileURL.path,
        networkAllowed: sandboxPolicy.networkAllowed,
        readOnlyRootFilesystem: true
      )),
      workingDirectory: workingDirectory
    )
    let run = try await runner.run(configuration: runConfiguration, stdin: stdin, deadline: context.deadline)
    guard run.terminationStatus == 0 else {
      throw AdapterExecutionError(.providerError, "container add-on '\(registration.addonName)' failed: \(run.stderrSummary)")
    }
    let payload = try outputPayload(fromStdout: run.stdout, addonName: registration.addonName)
    return AdapterExecutionOutput(
      provider: "container-addon",
      model: registration.addonName,
      promptText: "",
      completionPassed: true,
      payload: payload
    )
  }

  private func selectedRegistration(for addon: WorkflowNodeAddonRef) throws -> ContainerAddonRegistration {
    let matches = registrations.filter { registration in
      registration.addonName == addon.name && registration.version == (addon.version ?? registration.version)
    }
    guard let selected = matches.first else {
      throw AdapterExecutionError(.providerError, "missing container add-on resolver for '\(addon.name)'")
    }
    guard matches.count == 1 else {
      throw AdapterExecutionError(.policyBlocked, "container add-on '\(addon.name)' matched multiple installed packages")
    }
    return selected
  }

  private func selectedRuntimeDriver() throws -> any ContainerRuntimeDriver {
    let discovery = ContainerRuntimeDiscovery(environment: environment)
    if let configured = discovery.configuredDriver() {
      return configured
    }
    if let available = discovery.selectedAvailableDriver() {
      return available
    }
    throw AdapterExecutionError(
      .providerError,
      "container add-on runtime is missing; install Apple Container with 'riela setup container' or set RIELA_CONTAINER_RUNTIME"
    )
  }

  private func addonExecutionInput(
    _ input: WorkflowAddonExecutionInput,
    registration: ContainerAddonRegistration
  ) throws -> AddonExecutionInput {
    let variables = addonVariables(for: input)
    var nodePayload: JSONObject = [
      "workflowId": .string(input.workflowId),
      "stepId": .string(input.stepId),
      "nodeId": .string(input.nodeId),
      "input": .object(input.resolvedInputPayload)
    ]
    if let config = input.addon.config {
      nodePayload["config"] = .object(config.mapValues { renderJSONTemplates($0, variables: variables) })
    }
    nodePayload["inputs"] = .object(renderAddonInputs(input.addon.inputs, variables: variables))
    if let env = input.addon.env {
      nodePayload["env"] = .object(env)
    }
    return AddonExecutionInput(
      addonName: registration.addonName,
      version: input.addon.version,
      nodePayload: nodePayload,
      variables: variables,
      attachments: input.attachments,
      source: .init(
        packageName: registration.packageName,
        addonName: registration.addonName,
        sourcePath: packageRelativePath(for: registration.addonRoot, packageRoot: registration.packageRoot)
      ),
      options: .init(timeoutSeconds: nil, allowDispatchIntents: false)
    )
  }

  private func resolvedContainerEnvironment(
    registration: ContainerAddonRegistration,
    artifactRoot: URL
  ) -> [String: String] {
    var selected: [String: String] = [:]
    let allowedHostEnvironment = Set(registration.capabilities.compactMap { capability -> String? in
      guard capability.name == "env.read" else {
        return nil
      }
      return capability.scope
    })
    for key in ["HOME", "PATH", "TMPDIR"] where allowedHostEnvironment.contains(key) {
      if let value = environment[key], !value.isEmpty {
        selected[key] = value
      }
    }
    selected["RIELA_ARTIFACT_DIR"] = artifactRoot.path
    return selected
  }

  private func outputPayload(fromStdout stdout: String, addonName: String) throws -> JSONObject {
    let records = stdout
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard records.count == 1 else {
      throw AdapterExecutionError(.invalidOutput, "container add-on '\(addonName)' stdout must contain exactly one JSONL output record")
    }
    guard let data = records[0].data(using: .utf8) else {
      throw AdapterExecutionError(.invalidOutput, "container add-on '\(addonName)' stdout JSONL output must be UTF-8")
    }
    let decoded: JSONValue
    do {
      decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      throw AdapterExecutionError(.invalidOutput, "container add-on '\(addonName)' stdout must contain valid JSONL: \(error.localizedDescription)")
    }
    guard case let .object(payload) = decoded else {
      throw AdapterExecutionError(.invalidOutput, "container add-on '\(addonName)' stdout JSONL output must contain a top-level JSON object")
    }
    return payload
  }

  private func processConfiguration(
    driver: any ContainerRuntimeDriver,
    arguments: [String],
    workingDirectory: URL
  ) -> LocalAgentProcessConfiguration {
    let invocation = processInvocation(executable: driver.executable, arguments: arguments)
    return LocalAgentProcessConfiguration(
      executableURL: invocation.executableURL,
      arguments: invocation.arguments,
      environment: environment,
      unsetEnvironmentKeys: ["RIELA_WORKFLOW_INPUT", "RIELA_WORKFLOW_OUTPUT"],
      workingDirectoryURL: workingDirectory
    )
  }

  private func processInvocation(executable: String, arguments: [String]) -> (executableURL: URL, arguments: [String]) {
    if executable.hasPrefix("/") {
      return (URL(fileURLWithPath: executable), arguments)
    }
    return (URL(fileURLWithPath: "/usr/bin/env"), [executable] + arguments)
  }

  private func artifactRootURL() -> URL {
    if let configured = environment["RIELA_ARTIFACT_DIR"], !configured.isEmpty {
      return URL(fileURLWithPath: configured, isDirectory: true)
    }
    return workingDirectory.appendingPathComponent(".riela/artifacts", isDirectory: true)
  }

  private func imageTag(for registration: ContainerAddonRegistration) -> String {
    let digest = registration.contentDigest.replacingOccurrences(of: "sha256:", with: "")
    let suffix = String(digest.prefix(16))
    return "riela-addon-\(safeImageToken(registration.packageName))-\(safeImageToken(registration.addonName)):\(suffix)"
  }

  private func imageReference(
    for registration: ContainerAddonRegistration,
    driver: any ContainerRuntimeDriver,
    deadline: Date?
  ) async throws -> String {
    if let image = registration.image?.trimmingCharacters(in: .whitespacesAndNewlines), !image.isEmpty {
      let digest = registration.imageDigest?.trimmingCharacters(in: .whitespacesAndNewlines)
      if let digest, !digest.isEmpty {
        return appendDigestIfNeeded(image: image, digest: digest)
      }
      if registration.containerfilePath == nil {
        return image
      }
    }
    guard let containerfilePath = registration.containerfilePath else {
      throw AdapterExecutionError(.providerError, "container add-on '\(registration.addonName)' is missing an image or Containerfile")
    }
    let image = imageTag(for: registration)
    let containerfile = resolvedContainerfileURL(containerfilePath, registration: registration)
    guard FileManager.default.fileExists(atPath: containerfile.path) else {
      throw AdapterExecutionError(.providerError, "container add-on '\(registration.addonName)' is missing Containerfile: \(containerfile.path)")
    }

    let buildConfiguration = processConfiguration(
      driver: driver,
      arguments: driver.buildArguments(
        image: image,
        containerfile: containerfile,
        contextDirectory: registration.addonRoot
      ),
      workingDirectory: registration.addonRoot
    )
    let build = try await runner.run(configuration: buildConfiguration, stdin: "", deadline: deadline)
    guard build.terminationStatus == 0 else {
      throw AdapterExecutionError(.providerError, "container add-on '\(registration.addonName)' image build failed: \(build.stderrSummary)")
    }
    return image
  }

  private func resolvedContainerfileURL(
    _ containerfilePath: String,
    registration: ContainerAddonRegistration
  ) -> URL {
    let packageRelative = registration.packageRoot.appendingPathComponent(containerfilePath)
    if FileManager.default.fileExists(atPath: packageRelative.path) {
      return packageRelative
    }
    return registration.addonRoot.appendingPathComponent(containerfilePath)
  }

  private func appendDigestIfNeeded(image: String, digest: String?) -> String {
    guard let digest, !digest.isEmpty, !image.contains("@sha256:") else {
      return image
    }
    return "\(image)@\(digest)"
  }

  private func safeImageToken(_ value: String) -> String {
    let scalars = value.lowercased().unicodeScalars.map { scalar -> UnicodeScalar in
      let isAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-").contains(scalar)
      return isAllowed ? scalar : "-"
    }
    let token = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
    return token.isEmpty ? "addon" : token
  }

  private func jsonLine<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let text = String(data: data, encoding: .utf8) else {
      throw AdapterExecutionError(.providerError, "failed to encode container add-on input as UTF-8")
    }
    return text + "\n"
  }
}

private struct ContainerAddonSandboxPolicy {
  var mounts: [ContainerRuntimeMount]
  var networkAllowed: Bool

  init(
    registration: ContainerAddonRegistration,
    workingDirectory: URL,
    artifactRoot: URL,
    addonInput: AddonExecutionInput
  ) throws {
    self.networkAllowed = registration.capabilities.contains { capability in
      capability.name == "network.egress" && capability.defaultPolicy != "deny"
    }
    let declaredMounts = try Self.declaredMounts(
      capabilities: registration.capabilities,
      workingDirectory: workingDirectory,
      artifactRoot: artifactRoot,
      addonInput: addonInput
    )
    try Self.validatePayloadPaths(
      in: .object(addonInput.nodePayload),
      coveredBy: declaredMounts,
      addonName: registration.addonName
    )
    self.mounts = declaredMounts.sorted { $0.volumeArgument < $1.volumeArgument }
  }

  private static func declaredMounts(
    capabilities: [WorkflowAddonCapability],
    workingDirectory: URL,
    artifactRoot: URL,
    addonInput: AddonExecutionInput
  ) throws -> [ContainerRuntimeMount] {
    var mountsBySource: [String: ContainerRuntimeMount] = [
      artifactRoot.standardizedFileURL.path: ContainerRuntimeMount(
        source: artifactRoot.standardizedFileURL.path,
        target: artifactRoot.standardizedFileURL.path,
        readOnly: false
      )
    ]
    for capability in capabilities where capability.name == "filesystem.read" || capability.name == "filesystem.write" {
      let readOnly = capability.name == "filesystem.read"
      switch normalizedScope(capability.scope) {
      case "addon.input":
        for mount in try addonInputMounts(
          in: .object(addonInput.nodePayload),
          workingDirectory: workingDirectory,
          readOnly: readOnly
        ) {
          mergeMount(mount, into: &mountsBySource)
        }
      case "runtime.output":
        mergeMount(
          ContainerRuntimeMount(
            source: artifactRoot.standardizedFileURL.path,
            target: artifactRoot.standardizedFileURL.path,
            readOnly: readOnly
          ),
          into: &mountsBySource
        )
      default:
        let source = try scopedFilesystemURL(
          capability.scope,
          workingDirectory: workingDirectory,
          addonName: capability.name
        )
        mergeMount(
          ContainerRuntimeMount(source: source.path, target: source.path, readOnly: readOnly),
          into: &mountsBySource
        )
      }
    }
    return Array(mountsBySource.values)
  }

  private static func normalizedScope(_ scope: String?) -> String {
    scope?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
  }

  private static func scopedFilesystemURL(
    _ scope: String?,
    workingDirectory: URL,
    addonName: String
  ) throws -> URL {
    let trimmedScope = scope?.trimmingCharacters(in: .whitespacesAndNewlines)
    let url: URL
    if trimmedScope == nil || trimmedScope == "" || trimmedScope == "repo" {
      url = workingDirectory
    } else if let trimmedScope, trimmedScope.hasPrefix("/") || trimmedScope.hasPrefix("~") {
      url = URL(fileURLWithPath: (trimmedScope as NSString).expandingTildeInPath)
    } else {
      url = workingDirectory.appendingPathComponent(trimmedScope ?? ".", isDirectory: true)
    }
    let standardized = url.standardizedFileURL
    guard standardized.path != "/" else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) may not mount the filesystem root")
    }
    return standardized
  }

  private static func mergeMount(
    _ mount: ContainerRuntimeMount,
    into mountsBySource: inout [String: ContainerRuntimeMount]
  ) {
    guard let existing = mountsBySource[mount.source] else {
      mountsBySource[mount.source] = mount
      return
    }
    mountsBySource[mount.source] = ContainerRuntimeMount(
      source: mount.source,
      target: mount.target,
      readOnly: existing.readOnly && mount.readOnly
    )
  }

  private static func validatePayloadPaths(
    in value: JSONValue,
    coveredBy mounts: [ContainerRuntimeMount],
    addonName: String
  ) throws {
    for path in absolutePathStrings(in: value) {
      let expanded = (path as NSString).expandingTildeInPath
      let url = URL(fileURLWithPath: expanded)
      let mountURL = pathLooksLikeDirectory(expanded) ? url : url.deletingLastPathComponent()
      let candidatePaths = [
        url.standardizedFileURL.path,
        mountURL.standardizedFileURL.path
      ]
      guard mounts.contains(where: { mount in
        candidatePaths.contains { path in hasPathPrefix(path, prefix: mount.source) }
      }) else {
        throw AdapterExecutionError(
          .policyBlocked,
          "container add-on '\(addonName)' input path is not covered by filesystem capabilities: \(expanded)"
        )
      }
    }
  }

  private static func addonInputMounts(
    in value: JSONValue,
    workingDirectory: URL,
    readOnly: Bool
  ) throws -> [ContainerRuntimeMount] {
    let paths = addonInputPathStrings(in: value)
    return try paths.map { path in
      let expanded = (path as NSString).expandingTildeInPath
      let url = expanded.hasPrefix("/")
        ? URL(fileURLWithPath: expanded)
        : workingDirectory.appendingPathComponent(expanded)
      let mountURL = pathLooksLikeDirectory(expanded) ? url : url.deletingLastPathComponent()
      let source = mountURL.standardizedFileURL.path
      guard source != "/" else {
        throw AdapterExecutionError(.policyBlocked, "addon.input may not mount the filesystem root")
      }
      return ContainerRuntimeMount(source: source, target: source, readOnly: readOnly)
    }
  }

  private static func addonInputPathStrings(in value: JSONValue) -> [String] {
    switch value {
    case let .object(object):
      return object.flatMap { key, value -> [String] in
        switch value {
        case let .string(text) where keyLooksLikeInputPath(key) && stringLooksLikeLocalPath(text):
          return [text]
        default:
          return addonInputPathStrings(in: value)
        }
      }
    case let .array(values):
      return values.flatMap { addonInputPathStrings(in: $0) }
    case .null, .bool, .integer, .number, .string:
      return []
    }
  }

  private static func keyLooksLikeInputPath(_ key: String) -> Bool {
    let normalized = key.lowercased()
    return normalized.hasSuffix("path")
      || normalized.hasSuffix("file")
      || normalized.hasSuffix("filename")
  }

  private static func stringLooksLikeLocalPath(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("://") else {
      return false
    }
    return trimmed.hasPrefix("/")
      || trimmed.hasPrefix("~/")
      || trimmed.hasPrefix("./")
      || trimmed.hasPrefix("../")
      || trimmed.contains("/")
      || URL(fileURLWithPath: trimmed).pathExtension.isEmpty == false
  }

  private static func absolutePathStrings(in value: JSONValue) -> [String] {
    switch value {
    case let .string(text):
      let expanded = (text as NSString).expandingTildeInPath
      return expanded.hasPrefix("/") ? [expanded] : []
    case let .array(values):
      return values.flatMap { absolutePathStrings(in: $0) }
    case let .object(object):
      return object.flatMap { absolutePathStrings(in: $0.value) }
    case .null, .bool, .integer, .number:
      return []
    }
  }

  private static func pathLooksLikeDirectory(_ path: String) -> Bool {
    path.hasSuffix("/") || path.lowercased().contains("directory")
  }

  private static func hasPathPrefix(_ path: String, prefix: String) -> Bool {
    path == prefix || path.hasPrefix(prefix + "/")
  }
}

struct CompositeWorkflowAddonResolver: WorkflowAddonResolving {
  var primary: any WorkflowAddonResolving
  var fallback: any WorkflowAddonResolving

  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    if input.addon.name.hasPrefix("riela/") {
      return try await primary.execute(input, context: context)
    }
    return try await fallback.execute(input, context: context)
  }
}

extension LocalAgentProcessResult {
  fileprivate var stderrSummary: String {
    let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "no stderr" : trimmed
  }
}
