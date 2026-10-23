import Foundation
import RielaAdapters
import RielaAddons
import RielaAddonSupport
import RielaCore

enum ContainerGatewayAddon: String, Sendable {
  case xRead = "riela/x-gateway-read"
  case gmailRead = "riela/gmail-gateway-read"

  var entrypoint: String {
    switch self {
    case .xRead: "x-gateway-reader"
    case .gmailRead: "gmail-gateway-reader"
    }
  }

  var namespace: String {
    switch self {
    case .xRead: "xGateway"
    case .gmailRead: "gmailGateway"
    }
  }

  var defaultImage: String {
    switch self {
    case .xRead: RielaBuiltinGatewayContainerImages.x
    case .gmailRead: RielaBuiltinGatewayContainerImages.gmail
    }
  }

  func arguments(document: String) -> [String] {
    switch self {
    case .xRead: ["graphql", "query", document, "--json"]
    case .gmailRead: ["graphql", "--query", document]
    }
  }
}

/// Executes the pinned read-only gateway surface, never a shell command.
/// The image must contain the gateway reader executable on its PATH.
struct ContainerGatewayAddonExecutor {
  var environment: [String: String]
  var workingDirectory: URL
  var runner: any LocalProcessRunning
  var hostPlatform: RielaHostPlatform = .current

  func execute(
    _ input: WorkflowAddonExecutionInput,
    gateway: ContainerGatewayAddon,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version")
    }
    let config = input.addon.config ?? [:]
    let document: String
    if config["operation"] != nil {
      if gateway == .xRead {
        guard let built = try builtinGatewayXJSONDocument(input) else {
          throw AdapterExecutionError(.policyBlocked, "X JSON operation is missing")
        }
        document = built
      } else {
        guard let catalog = try BuiltinGmailGatewayCLIAddon.reader.descriptor.catalog?() else {
          throw AdapterExecutionError(.policyBlocked, "Gmail reader catalog is unavailable")
        }
        let built = try BuiltinGatewayJSONRequest.document(config: config, variables: addonVariables(for: input),
          catalog: catalog, addonName: input.addon.name)
        document = try BuiltinGatewayJSONRequest.inlineReaderDocument(built, catalog: catalog)
      }
    } else {
      guard config["arguments"] == nil, config["selection"] == nil, config["select"] == nil,
            let template = nonEmptyString(config["queryTemplate"]) else {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) config.queryTemplate is required; JSON arguments require operation")
      }
      document = renderPromptTemplate(template, variables: try addonVariables(for: input))
    }
    if config["operation"] != nil, document.utf8.count > 120_000 {
      throw AdapterExecutionError(.policyBlocked, "gateway JSON document exceeds the legacy container argument limit")
    }
    let driver = try runtimeDriver(config: config)
    if let value = config["image"], nonEmptyString(value) == nil {
      throw AdapterExecutionError(.policyBlocked, "config.image must be a non-empty string")
    }
    let image = nonEmptyString(config["image"]) ?? gateway.defaultImage
    let networkPolicy = try networkPolicy(config: config)
    let mounts = try mounts(config: config)
    let home = URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(environment: environment), isDirectory: true)
    try BuiltinAddonContainerTransportStore.validateIsolation(mountSources: mounts.map { URL(fileURLWithPath: $0.source) },
      controlDirectory: BuiltinAddonContainerTransportStore.defaultRoot(for: workingDirectory, home: home))
    if driver.kind == .appleContainer {
      for mount in mounts {
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: mount.source, isDirectory: &isDirectory)
        guard isDirectory.boolValue else {
          throw AdapterExecutionError(.policyBlocked, "Apple Container mounts require a directory source; mount its directory and use the file path inside the container")
        }
      }
    }
    // Docker/Podman name-only forwarding also puts keys in the host runtime process.
    // Restrict targets to provider namespaces so bindings cannot override PATH,
    // runtime connection settings, dynamic loaders, or interpreter startup hooks.
    for name in input.addon.env?.keys ?? [:].keys {
      guard name.range(of: #"^(X_GW_|GMAIL_GATEWAY_)[A-Z0-9_]+\z"#, options: .regularExpression) != nil else {
        throw AdapterExecutionError(.policyBlocked, "gateway addon.env targets must use X_GW_ or GMAIL_GATEWAY_ uppercase names")
      }
    }
    let userCache = try gateway == .xRead ? XGatewayUserCacheExchange(input: input, workingDirectory: workingDirectory, environment: environment) : nil
    let gatewayEnvironment = try resolveAddonEnvironment(input.addon.env, runtimeEnvironment: environment)
      .merging(userCache?.bindings() ?? [:]) { _, memory in memory }
    let result: LocalProcessResult
    if driver.kind == .appleContainer {
      result = try await AppleContainerGatewayProcess(executable: driver.executable, environment: runtimeProcessEnvironment,
        workingDirectory: workingDirectory, runner: runner).run(image: image, mounts: mounts,
          networkAllowed: networkPolicy == .egressAllowed, gateway: gateway, document: document,
          bindings: gatewayEnvironment, deadline: context.deadline)
    } else {
      var arguments = driver.runArguments(image: image, options: ContainerRuntimeRunOptions(
        environment: gatewayEnvironment,
        mounts: mounts,
        entrypoint: gateway.entrypoint,
        workingDirectory: nil,
        networkAllowed: networkPolicy == .egressAllowed,
        readOnlyRootFilesystem: true,
        environmentValuesFromProcess: true,
        disablePersistentLogs: true
      ))
      arguments += gateway.arguments(document: document)
      let executable = driver.executable
      let configuration = LocalProcessConfiguration(
        executableURL: URL(fileURLWithPath: executable.hasPrefix("/") ? executable : "/usr/bin/env"),
        arguments: executable.hasPrefix("/") ? arguments : [executable] + arguments,
        environment: runtimeProcessEnvironment.merging(gatewayEnvironment) { _, bound in bound },
        unsetEnvironmentKeys: ["RIELA_WORKFLOW_INPUT", "RIELA_WORKFLOW_OUTPUT"],
        workingDirectoryURL: workingDirectory,
        inheritEnvironment: false
      )
      result = try await runner.run(configuration: configuration, stdin: "", deadline: context.deadline)
    }
    // Do not surface raw gateway stderr: it may contain provider credentials.
    guard result.terminationStatus == 0 else {
      throw AdapterExecutionError(.providerError, "\(input.addon.name) container failed with exit code \(result.terminationStatus)"
        + GatewayFailureDiagnostics.suffix(stdout: result.stdout, stderr: result.stderr))
    }
    let response: JSONObject
    let stdout = try userCache?.consume(result.stdout) ?? result.stdout
    do {
      response = try JSONDecoder().decode(JSONObject.self, from: Data(stdout.utf8))
    } catch {
      throw AdapterExecutionError(.invalidOutput, "\(input.addon.name) container must return one JSON object")
    }
    guard response["ok"] != .bool(false), response["error"] == nil,
          nonEmptyString(response["status"]) != "error", !containsGraphQLErrors(response) else {
      throw AdapterExecutionError(.providerError, "\(input.addon.name) gateway returned an error"
        + GatewayFailureDiagnostics.suffix(stdout: result.stdout))
    }
    guard case .object? = response["data"] else {
      throw AdapterExecutionError(.invalidOutput, "\(input.addon.name) gateway response is missing data")
    }
    // The Swift X CLI wraps the GraphQL envelope in {ok, data}. Digest
    // consumers expect the GraphQL envelope itself at xGateway.data.
    let gatewayData = gateway == .xRead && response["ok"] == .bool(true)
      ? response["data"] ?? .object(response) : .object(response)
    return AdapterExecutionOutput(
      provider: "container-addon",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      payload: [
        "status": .string("ok"),
        "addon": .string(input.addon.name),
        "stepId": .string(input.stepId),
        gateway.namespace: .object([
          "data": gatewayData,
          "response": .object(response),
          "runtime": .object(["kind": .string(driver.kind.rawValue), "image": .string(image)])
        ])
      ]
    )
  }

  // Runtime connection/configuration variables are host concerns; unrelated workflow
  // secrets must not reach the runtime process. Container bindings are merged explicitly.
  private var runtimeProcessEnvironment: [String: String] {
    let keys: Set<String> = [
      "PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
      "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR", "XDG_DATA_HOME",
      "DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH",
      "DOCKER_API_VERSION", "CONTAINER_HOST", "CONTAINER_CONNECTION", "CONTAINER_SSHKEY",
      "CONTAINERS_CONF", "CONTAINERS_REGISTRIES_CONF", "REGISTRY_AUTH_FILE", "SSH_AUTH_SOCK",
      "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy"
    ]
    return environment.filter { keys.contains($0.key) }
  }

  private func runtimeDriver(config: JSONObject) throws -> any ContainerRuntimeDriver {
    var selectedEnvironment = environment
    if let value = config["runnerKind"] {
      guard case let .string(kind) = value,
            ["auto", "apple-container", "container", "docker", "podman"].contains(kind) else {
        throw AdapterExecutionError(.policyBlocked, "unsupported config.runnerKind")
      }
    }
    if selectedEnvironment["RIELA_CONTAINER_RUNTIME"]?.isEmpty != false,
       let kind = nonEmptyString(config["runnerKind"]), kind != "auto" {
      switch kind {
      case "apple-container", "container": selectedEnvironment["RIELA_CONTAINER_RUNTIME"] = "container"
      case "docker", "podman": selectedEnvironment["RIELA_CONTAINER_RUNTIME"] = kind
      default: throw AdapterExecutionError(.policyBlocked, "unsupported container runnerKind '\(kind)'")
      }
    }
    let discovery = ContainerRuntimeDiscovery(environment: selectedEnvironment, hostPlatform: hostPlatform)
    guard !discovery.configuredAppleContainerIsUnsupported else {
      throw AdapterExecutionError(.providerError, "Apple Container is only available on Darwin hosts")
    }
    guard let driver = discovery.configuredDriver() ?? discovery.selectedAvailableDriver() else {
      throw AdapterExecutionError(.providerError, "container runtime is missing; run 'riela setup container' or set RIELA_CONTAINER_RUNTIME")
    }
    return driver
  }

  private enum NetworkPolicy: String {
    case denied
    case egressAllowed = "egress-allowed"
  }

  private func networkPolicy(config: JSONObject) throws -> NetworkPolicy {
    guard let value = config["networkPolicy"] else { return .egressAllowed }
    guard case let .string(raw) = value, let policy = NetworkPolicy(rawValue: raw) else {
      throw AdapterExecutionError(.policyBlocked, "config.networkPolicy must be denied or egress-allowed")
    }
    return policy
  }

  private func mounts(config: JSONObject) throws -> [ContainerRuntimeMount] {
    guard let value = config["mounts"] else { return [] }
    guard case let .array(values) = value else {
      throw AdapterExecutionError(.policyBlocked, "config.mounts must be an array")
    }
    var targets = Set<String>()
    return try values.map { value in
      guard case let .object(mount) = value,
            let source = nonEmptyString(mount["source"]),
            let target = nonEmptyString(mount["target"]), target.hasPrefix("/") else {
        throw AdapterExecutionError(.policyBlocked, "each config.mounts entry requires source and an absolute target")
      }
      let sourceURL = source.hasPrefix("/") ? URL(fileURLWithPath: source) : workingDirectory.appendingPathComponent(source)
      let sourcePath = sourceURL.standardizedFileURL.path
      let targetPath = URL(fileURLWithPath: target).standardizedFileURL.path
      guard sourcePath != "/", targetPath != "/", targets.insert(targetPath).inserted,
            !sourcePath.contains(","), !sourcePath.contains(":"), !targetPath.contains(","), !targetPath.contains(":"),
            FileManager.default.fileExists(atPath: sourcePath) else {
        throw AdapterExecutionError(.policyBlocked, "invalid, missing, or duplicate gateway container mount")
      }
      let readOnly: Bool
      if let value = mount["readOnly"] {
        guard case let .bool(flag) = value else {
          throw AdapterExecutionError(.policyBlocked, "config.mounts.readOnly must be a boolean")
        }
        readOnly = flag
      } else {
        readOnly = true
      }
      return ContainerRuntimeMount(source: sourcePath, target: targetPath, readOnly: readOnly)
    }
  }

  private func containsGraphQLErrors(_ object: JSONObject) -> Bool {
    if case let .array(errors)? = object["errors"], !errors.isEmpty { return true }
    if case let .object(data)? = object["data"] { return containsGraphQLErrors(data) }
    return false
  }
}
