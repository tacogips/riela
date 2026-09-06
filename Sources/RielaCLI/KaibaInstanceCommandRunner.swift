import Foundation
import RielaKaibaSupport

public struct KaibaInstanceCommandRunner: Sendable {
  public init() {}

  // The dispatch keeps the contract-required validation ordering visible.
  public func run(_ options: CLICommandOptions) async -> CLICommandResult {
    let output = KaibaOutput.requested(in: options.arguments)
    let operation = KaibaOperation.renderedName(for: options.command)
    var knownInstance: KaibaInstance?
    do {
      if options.command == "help" {
        return .init(exitCode: .success, stdout: helpText)
      }
      let store = KaibaInstanceStore(homeURL: URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(), isDirectory: true))
      let arguments = try KaibaArguments(options.arguments)
      try arguments.validateSyntax(for: options.command)
      if KaibaOperation.requiresSelector(options.command), let selector = try? arguments.requiredSelector() {
        knownInstance = try? instance(from: store.load(), selector: selector)
      }
      let outcome = try await execute(options.command, arguments: arguments, store: store, output: output)
      knownInstance = outcome.instance
      return outcome.result
    } catch is CLIUsageError {
      return renderFailure(operation: operation, failure: .usage, output: output, instance: knownInstance)
    } catch let error as KaibaInstanceStoreError {
      return renderFailure(operation: operation, failure: KaibaCommandFailure(storeError: error), output: output, instance: knownInstance)
    } catch is KaibaBindingScannerError {
      return renderFailure(operation: operation, failure: .bindingScanFailed, output: output, instance: knownInstance)
    } catch CommandError.staleTest {
      return renderFailure(operation: operation, failure: .changed, output: output, instance: knownInstance)
    } catch let error as KaibaCommandFailure {
      return renderFailure(operation: operation, failure: error, output: output, instance: knownInstance)
    } catch {
      return renderFailure(operation: operation, failure: .unavailableStore, output: output, instance: knownInstance)
    }
  }

  private func instance(from catalog: KaibaInstanceCatalog, selector: String) throws -> KaibaInstance {
    let matchingName = KaibaInstanceValidation.nameKey(selector)
    guard let instance = catalog.instances.first(where: { $0.id == selector || KaibaInstanceValidation.nameKey($0.name) == matchingName }) else {
      throw KaibaInstanceStoreError.missingInstance
    }
    return instance
  }

  private func execute(
    _ command: String?,
    arguments: KaibaArguments,
    store: KaibaInstanceStore,
    output: KaibaOutput
  ) async throws -> KaibaCommandOutcome {
    switch command {
    case "list": try list(arguments, store: store, output: output)
    case "show": try show(arguments, store: store, output: output)
    case "add": try add(arguments, store: store, output: output)
    case "update": try update(arguments, store: store, output: output)
    case "remove": try remove(arguments, store: store, output: output)
    case "set-default": try setDefault(arguments, store: store, output: output)
    case "test": try await test(arguments, store: store, output: output)
    default: throw KaibaCommandFailure.usage
    }
  }

  private func list(_ arguments: KaibaArguments, store: KaibaInstanceStore, output: KaibaOutput) throws -> KaibaCommandOutcome {
    try arguments.requireNoPositionals()
    try arguments.requireOnly([])
    let result = try renderSuccess(operation: "list", instances: store.load().instances.sorted(by: KaibaInstanceOrdering.less), output: output)
    return .init(result: result)
  }

  private func show(_ arguments: KaibaArguments, store: KaibaInstanceStore, output: KaibaOutput) throws -> KaibaCommandOutcome {
    let selector = try arguments.requiredSelector()
    try arguments.requireOnly([])
    let selected = try instance(from: store.load(), selector: selector)
    return .init(result: try renderSuccess(operation: "show", instance: selected, output: output), instance: selected)
  }

  private func add(_ arguments: KaibaArguments, store: KaibaInstanceStore, output: KaibaOutput) throws -> KaibaCommandOutcome {
    let name = try arguments.requiredSelector()
    try arguments.requireOnly([.endpoint, .apiKeyEnvironment, .allowUnauthenticated, .allowInsecureHTTP, .allowRemoteUnauthenticated, .setDefault])
    let instance = try arguments.newInstance(name: name, defaulted: store.load().instances.isEmpty)
    let result = try store.mutate { catalog in
      try rejectDuplicateName(instance.name, excluding: nil, catalog: catalog)
      var updated = catalog
      if instance.isDefault {
        for index in updated.instances.indices { updated.instances[index].isDefault = false }
      }
      updated.instances.append(instance)
      return updated
    }
    let saved = try requiredInstance(id: instance.id, in: result)
    return .init(result: try renderSuccess(operation: "add", instance: saved, output: output), instance: saved)
  }

  private func update(_ arguments: KaibaArguments, store: KaibaInstanceStore, output: KaibaOutput) throws -> KaibaCommandOutcome {
    let selector = try arguments.requiredSelector()
    try arguments.requireOnly([.name, .endpoint, .apiKeyEnvironment, .allowUnauthenticated, .allowInsecureHTTP, .allowRemoteUnauthenticated, .enable, .disable])
    let original = try instance(from: store.load(), selector: selector)
    let replacement = try KaibaInstanceLifecycle.applyingUpdate(from: original, to: try arguments.updated(original), at: Date())
    try rejectDuplicateName(replacement.name, excluding: original.id, catalog: try store.load())
    if original.isDefault && !replacement.enabled { throw KaibaCommandFailure.defaultReplacementRequired }
    let result = try store.mutateInstance(id: original.id, expected: original) { _ in replacement }
    let saved = try requiredInstance(id: original.id, in: result)
    return .init(result: try renderSuccess(operation: "update", instance: saved, output: output), instance: saved)
  }

  private func remove(_ arguments: KaibaArguments, store: KaibaInstanceStore, output: KaibaOutput) throws -> KaibaCommandOutcome {
    let selector = try arguments.requiredSelector()
    try arguments.requireOnly([.force, .workingDirectory, .appRoot])
    let selected = try instance(from: store.load(), selector: selector)
    let roots = try arguments.removalRoots(homeURL: store.homeURL)
    var affectedReferences: [KaibaBindingReference] = []
    _ = try store.mutate { catalog in
      guard let current = catalog.instances.first(where: { $0.id == selected.id }) else { throw KaibaInstanceStoreError.missingInstance }
      guard current == selected else { throw KaibaInstanceStoreError.changedInstance }
      if current.isDefault && catalog.instances.count > 1 { throw KaibaCommandFailure.defaultReplacementRequired }
      affectedReferences = try KaibaBindingScanner().references(to: current.id, roots: roots)
      guard arguments.allowsForcedRemoval || affectedReferences.isEmpty else { throw KaibaCommandFailure.instanceInUse }
      var updated = catalog
      updated.instances.removeAll { $0.id == current.id }
      return updated
    }
    return .init(result: try renderRemovalSuccess(instance: selected, references: affectedReferences, output: output), instance: selected)
  }

  private func setDefault(_ arguments: KaibaArguments, store: KaibaInstanceStore, output: KaibaOutput) throws -> KaibaCommandOutcome {
    let selector = try arguments.requiredSelector()
    try arguments.requireOnly([])
    let selected = try instance(from: store.load(), selector: selector)
    guard selected.enabled else { throw KaibaCommandFailure.disabled }
    let result = try store.mutate { catalog in
      var updated = catalog
      guard updated.instances.contains(where: { $0.id == selected.id && $0.enabled }) else { throw KaibaInstanceStoreError.missingInstance }
      for index in updated.instances.indices { updated.instances[index].isDefault = updated.instances[index].id == selected.id }
      return updated
    }
    let saved = try requiredInstance(id: selected.id, in: result)
    return .init(result: try renderSuccess(operation: "set-default", instance: saved, output: output), instance: saved)
  }

  private func test(_ arguments: KaibaArguments, store: KaibaInstanceStore, output: KaibaOutput) async throws -> KaibaCommandOutcome {
    let selector = try arguments.requiredSelector()
    try arguments.requireOnly([])
    let instance = try instance(from: store.load(), selector: selector)
    guard instance.enabled else {
      _ = try store.mutateInstance(id: instance.id, expected: instance) { current in
        var updated = current
        updated.lastTest = KaibaInstanceLifecycle.disabledResult(at: Date())
        return updated
      }
      throw KaibaCommandFailure.disabled
    }
    let lastTest: KaibaInstanceLastTest
    do {
      let client = try KaibaClientFactory().makeClient(instance: instance, environment: CLIRuntimeEnvironment.mergedProcessEnvironment())
      lastTest = try await KaibaReadinessService().test(client)
    } catch let error as KaibaClientFactoryError {
      if error == .missingCredential {
        _ = try persistLastTest(.init(status: .missingCredential, code: KaibaCommandFailure.missingCredential.code, attemptedAt: Date()), for: instance, store: store)
        throw KaibaCommandFailure.missingCredential
      }
      throw KaibaCommandFailure.incompatible
    }
    let tested = try requiredInstance(id: instance.id, in: persistLastTest(lastTest, for: instance, store: store))
    switch tested.lastTest.status {
    case .ready: return .init(result: try renderSuccess(operation: "test", instance: tested, output: output), instance: tested)
    case .authFailed: throw KaibaCommandFailure.authFailed
    case .connectionFailed: throw KaibaCommandFailure.connectionFailed
    case .missingCredential: throw KaibaCommandFailure.missingCredential
    case .disabled: throw KaibaCommandFailure.disabled
    case .untested, .incompatible: throw KaibaCommandFailure.incompatible
    }
  }

  private func requiredInstance(id: String, in catalog: KaibaInstanceCatalog) throws -> KaibaInstance {
    guard let instance = catalog.instances.first(where: { $0.id == id }) else { throw KaibaInstanceStoreError.missingInstance }
    return instance
  }

  private func rejectDuplicateName(_ name: String, excluding id: String?, catalog: KaibaInstanceCatalog) throws {
    guard !catalog.instances.contains(where: { $0.id != id && KaibaInstanceValidation.nameKey($0.name) == KaibaInstanceValidation.nameKey(name) }) else {
      throw KaibaCommandFailure.duplicateName
    }
  }

  private func renderSuccess(
    operation: String,
    instance: KaibaInstance? = nil,
    instances: [KaibaInstance]? = nil,
    output: KaibaOutput
  ) throws -> CLICommandResult {
    if output == .json {
      return try renderJSON(KaibaSuccessDTO(operation: operation, instance: instance, instances: instances))
    }
    if let instances {
      let rows = instances.map(KaibaInstanceDTO.init)
      let header = "DEFAULT ENABLED NAME ENDPOINT AUTH LAST TEST"
      let values = rows.map { row in
        "\(row.isDefault ? "yes" : "no") \(row.enabled ? "yes" : "no") \(row.name) \(row.endpoint) \(row.authenticationMode) \(row.lastTest.status)"
      }
      return .init(exitCode: .success, stdout: ([header] + values).joined(separator: "\n") + "\n")
    }
    guard let instance else { throw KaibaCommandFailure.usage }
    if operation == "show" {
      return .init(exitCode: .success, stdout: instanceText(instance))
    }
    let verb = ["add": "Added", "update": "Updated", "test": "Tested", "set-default": "Default"][operation] ?? operation
    return .init(exitCode: .success, stdout: "\(verb) \(instance.id) \(instance.name)\n")
  }

  private func renderRemovalSuccess(
    instance: KaibaInstance,
    references: [KaibaBindingReference],
    output: KaibaOutput
  ) throws -> CLICommandResult {
    if output == .json {
      return try renderJSON(KaibaRemovalSuccessDTO(instance: instance, references: references))
    }
    let referenceLines = references.map { reference in
      "AFFECTED: \(reference.scope.rawValue) \(reference.profile ?? "-") \(reference.workflowId) \(reference.nodeId) \(reference.bindingOrigin.rawValue) \(reference.sourcePath)"
    }
    return .init(exitCode: .success, stdout: (["Removed \(instance.id) \(instance.name)"] + referenceLines).joined(separator: "\n") + "\n")
  }

  private func renderJSON<T: Encodable>(_ value: T) throws -> CLICommandResult {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    guard let rendered = String(data: data, encoding: .utf8) else {
      throw CLIUsageError("could not render Kaiba instance result")
    }
    return .init(exitCode: .success, stdout: rendered + "\n")
  }

  private func instanceText(_ instance: KaibaInstance) -> String {
    let value = KaibaInstanceDTO(instance)
    return [
      "DEFAULT: \(value.isDefault ? "yes" : "no")",
      "ENABLED: \(value.enabled ? "yes" : "no")",
      "NAME: \(value.name)",
      "ENDPOINT: \(value.endpoint)",
      "AUTH: \(value.authenticationMode)",
      "LAST TEST: \(value.lastTest.status)"
    ].joined(separator: "\n") + "\n"
  }

  private func sameTransport(_ lhs: KaibaInstance, _ rhs: KaibaInstance) -> Bool {
    lhs.endpoint == rhs.endpoint
      && lhs.authentication == rhs.authentication
      && lhs.enabled == rhs.enabled
      && lhs.allowInsecureHTTP == rhs.allowInsecureHTTP
      && lhs.allowRemoteUnauthenticated == rhs.allowRemoteUnauthenticated
  }

  private func persistLastTest(
    _ lastTest: KaibaInstanceLastTest,
    for instance: KaibaInstance,
    store: KaibaInstanceStore
  ) throws -> KaibaInstanceCatalog {
    try store.mutate { catalog in
      var updated = catalog
      guard let index = updated.instances.firstIndex(where: { $0.id == instance.id }) else {
        throw KaibaInstanceStoreError.missingInstance
      }
      guard sameTransport(updated.instances[index], instance) else {
        throw CommandError.staleTest
      }
      updated.instances[index].lastTest = lastTest
      return updated
    }
  }

  private var helpText: String {
    "Usage: riela kaiba instance list|show|add|update|remove|test|set-default [options]\n"
  }

  private func renderFailure(
    operation: String,
    failure: KaibaCommandFailure,
    output: KaibaOutput,
    instance: KaibaInstance?
  ) -> CLICommandResult {
    if output == .json, let result = try? jsonString(KaibaFailureDTO(operation: operation, failure: failure, instance: instance)) {
      return .init(exitCode: failure.exitCode, stderr: result)
    }
    return .init(exitCode: failure.exitCode, stderr: "\(failure.code): \(failure.message) Next: \(failure.nextAction)\n")
  }
}

private enum CommandError: Error {
  case staleTest
}

private struct KaibaCommandOutcome {
  var result: CLICommandResult
  var instance: KaibaInstance?

  init(result: CLICommandResult, instance: KaibaInstance? = nil) {
    self.result = result
    self.instance = instance
  }
}

private enum KaibaOperation {
  private static let names: Set<String> = ["list", "show", "add", "update", "remove", "test", "set-default"]
  private static let selectorNames: Set<String> = ["show", "update", "remove", "test", "set-default"]

  static func renderedName(for value: String?) -> String {
    guard let value, names.contains(value) else { return "instance" }
    return value
  }

  static func requiresSelector(_ value: String?) -> Bool {
    guard let value else { return false }
    return selectorNames.contains(value)
  }
}

private enum KaibaOutput: Equatable {
  case text
  case json

  static func requested(in tokens: [String]) -> KaibaOutput {
    guard let index = tokens.lastIndex(of: "--output"), tokens.indices.contains(index + 1) else { return .text }
    return tokens[index + 1] == "json" ? .json : .text
  }
}

private enum KaibaOption: String, CaseIterable {
  case output = "--output"
  case name = "--name"
  case endpoint = "--endpoint"
  case apiKeyEnvironment = "--api-key-env"
  case allowUnauthenticated = "--allow-unauthenticated"
  case allowInsecureHTTP = "--allow-insecure-http"
  case allowRemoteUnauthenticated = "--allow-remote-unauthenticated"
  case setDefault = "--set-default"
  case enable = "--enable"
  case disable = "--disable"
  case force = "--force"
  case workingDirectory = "--working-dir"
  case appRoot = "--app-root"

  var requiresValue: Bool {
    switch self {
    case .output, .name, .endpoint, .apiKeyEnvironment, .allowInsecureHTTP, .allowRemoteUnauthenticated, .workingDirectory, .appRoot: true
    case .allowUnauthenticated, .setDefault, .enable, .disable, .force: false
    }
  }
}

private struct KaibaArguments {
  private let positionals: [String]
  private let values: [KaibaOption: String]
  private let flags: Set<KaibaOption>
  private let provided: Set<KaibaOption>

  init(_ source: [String]) throws {
    var positionalValues: [String] = []
    var parsedValues: [KaibaOption: String] = [:]
    var parsedFlags = Set<KaibaOption>()
    var supplied = Set<KaibaOption>()
    var index = 0
    while source.indices.contains(index) {
      let token = source[index]
      guard token.hasPrefix("--") else {
        positionalValues.append(token)
        index += 1
        continue
      }
      guard let option = KaibaOption(rawValue: token), supplied.insert(option).inserted else { throw CLIUsageError("invalid Kaiba instance option") }
      if option.requiresValue {
        index += 1
        guard source.indices.contains(index), !source[index].hasPrefix("--") else { throw CLIUsageError("Kaiba instance option requires a value") }
        parsedValues[option] = source[index]
      } else {
        parsedFlags.insert(option)
      }
      index += 1
    }
    if let output = parsedValues[.output], output != "text", output != "json" { throw CLIUsageError("invalid Kaiba instance output") }
    positionals = positionalValues
    values = parsedValues
    flags = parsedFlags
    provided = supplied
  }

  func requireOnly(_ allowed: Set<KaibaOption>) throws {
    guard provided.subtracting(allowed.union([.output])).isEmpty else { throw CLIUsageError("unsupported Kaiba instance option") }
  }

  func requireNoPositionals() throws {
    guard positionals.isEmpty else { throw CLIUsageError("unexpected Kaiba instance argument") }
  }

  func validateSyntax(for command: String?) throws {
    switch command {
    case "list":
      try requireNoPositionals()
      try requireOnly([])
    case "show", "set-default", "test":
      _ = try requiredSelector()
      try requireOnly([])
    case "add":
      _ = try requiredSelector()
      try requireOnly([.endpoint, .apiKeyEnvironment, .allowUnauthenticated, .allowInsecureHTTP, .allowRemoteUnauthenticated, .setDefault])
      try validateAddOptionSyntax()
    case "update":
      _ = try requiredSelector()
      try requireOnly([.name, .endpoint, .apiKeyEnvironment, .allowUnauthenticated, .allowInsecureHTTP, .allowRemoteUnauthenticated, .enable, .disable])
      try validateUpdateOptionSyntax()
    case "remove":
      _ = try requiredSelector()
      try requireOnly([.force, .workingDirectory, .appRoot])
      _ = try directoryURL(for: .workingDirectory)
      _ = try directoryURL(for: .appRoot)
    default:
      throw CLIUsageError("unsupported Kaiba instance command")
    }
  }

  func requiredSelector() throws -> String {
    guard positionals.count == 1, let selector = positionals.first, !selector.isEmpty else { throw CLIUsageError("Kaiba instance selector is required") }
    return selector
  }

  var allowsForcedRemoval: Bool { flags.contains(.force) }

  private func validateAddOptionSyntax() throws {
    guard values[.endpoint] != nil else {
      throw CLIUsageError("Kaiba instance endpoint is required")
    }
    let hasBearerEnvironment = values[.apiKeyEnvironment] != nil
    let allowsUnauthenticated = flags.contains(.allowUnauthenticated)
    guard hasBearerEnvironment != allowsUnauthenticated else {
      throw KaibaCommandFailure.invalidAuthentication
    }
  }

  private func validateUpdateOptionSyntax() throws {
    guard !(provided.contains(.apiKeyEnvironment) && provided.contains(.allowUnauthenticated)),
          !(provided.contains(.enable) && provided.contains(.disable)) else {
      throw CLIUsageError("contradictory Kaiba instance options")
    }
    guard provided.subtracting([.output]).isEmpty == false else {
      throw CLIUsageError("an update option is required")
    }
    if let value = values[.allowInsecureHTTP] {
      _ = try parseBoolean(value)
    }
    if let value = values[.allowRemoteUnauthenticated] {
      _ = try parseBoolean(value)
    }
  }

  func removalRoots(homeURL: URL) throws -> KaibaBindingScanRoots {
    let workingDirectory = try directoryURL(for: .workingDirectory) ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let appRoot = try directoryURL(for: .appRoot) ?? homeURL
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("rielaapp", isDirectory: true)
    return .init(projectRootURL: workingDirectory, homeURL: homeURL, appRootURL: appRoot)
  }

  func newInstance(name: String, defaulted: Bool) throws -> KaibaInstance {
    guard let endpoint = values[.endpoint] else { throw CLIUsageError("Kaiba instance endpoint is required") }
    let normalizedName = try validateName(name)
    let bearer = values[.apiKeyEnvironment]
    let unauthenticated = flags.contains(.allowUnauthenticated)
    guard bearer != nil || unauthenticated, bearer == nil || !unauthenticated else { throw KaibaCommandFailure.invalidAuthentication }
    let instance = KaibaInstance(
      name: normalizedName,
      endpoint: endpoint,
      authentication: bearer.map { .bearer(environmentVariable: $0) } ?? .unauthenticated,
      isDefault: defaulted || flags.contains(.setDefault),
      allowInsecureHTTP: flags.contains(.allowInsecureHTTP),
      allowRemoteUnauthenticated: flags.contains(.allowRemoteUnauthenticated)
    )
    try validatePolicy(instance)
    return instance
  }

  func updated(_ base: KaibaInstance) throws -> KaibaInstance {
    var instance = base
    if let name = values[.name] { instance.name = try validateName(name) }
    if let endpoint = values[.endpoint] { instance.endpoint = endpoint }
    if let environment = values[.apiKeyEnvironment] { instance.authentication = .bearer(environmentVariable: environment) }
    if flags.contains(.allowUnauthenticated) { instance.authentication = .unauthenticated }
    if let value = values[.allowInsecureHTTP] { instance.allowInsecureHTTP = try parseBoolean(value) }
    if let value = values[.allowRemoteUnauthenticated] { instance.allowRemoteUnauthenticated = try parseBoolean(value) }
    if flags.contains(.enable) { instance.enabled = true }
    if flags.contains(.disable) { instance.enabled = false }
    try validatePolicy(instance)
    return instance
  }

  private func validateName(_ name: String) throws -> String {
    do {
      return try KaibaInstanceValidation.normalizedName(name)
    } catch {
      throw KaibaCommandFailure.invalidName
    }
  }

  private func validatePolicy(_ instance: KaibaInstance) throws {
    guard hasValidEndpointSyntax(instance.endpoint) else {
      throw KaibaCommandFailure.invalidEndpoint
    }
    do {
      try KaibaInstanceValidation.validateEndpoint(instance)
    } catch {
      throw KaibaCommandFailure.invalidAuthentication
    }
  }

  private func hasValidEndpointSyntax(_ value: String) -> Bool {
    guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
          let endpoint = URL(string: value),
          ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""),
          endpoint.host != nil,
          endpoint.path.isEmpty || endpoint.path == "/" || endpoint.path == "/graphql",
          endpoint.query == nil,
          endpoint.fragment == nil,
          endpoint.user == nil,
          endpoint.password == nil else {
      return false
    }
    return true
  }

  private func parseBoolean(_ value: String) throws -> Bool {
    switch value {
    case "true": true
    case "false": false
    default: throw CLIUsageError("Kaiba instance boolean option must be true or false")
    }
  }

  private func directoryURL(for option: KaibaOption) throws -> URL? {
    guard let value = values[option] else { return nil }
    guard value.hasPrefix("/") else { throw CLIUsageError("Kaiba instance directory options require absolute paths") }
    return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
  }
}

private enum KaibaInstanceOrdering {
  static func folded(_ value: String) -> String {
    KaibaInstanceValidation.nameKey(value)
  }

  static func less(_ lhs: KaibaInstance, _ rhs: KaibaInstance) -> Bool {
    let left = folded(lhs.name)
    let right = folded(rhs.name)
    return left == right ? lhs.id < rhs.id : left < right
  }
}

private enum KaibaCommandFailure: Error {
  case usage
  case invalidStore
  case unavailableStore
  case notFound
  case duplicateName
  case invalidName
  case invalidEndpoint
  case invalidAuthentication
  case defaultReplacementRequired
  case bindingScanFailed
  case instanceInUse
  case disabled
  case missingCredential
  case changed
  case authFailed
  case connectionFailed
  case incompatible

  init(storeError: KaibaInstanceStoreError) {
    switch storeError {
    case .invalidStore: self = .invalidStore
    case .unavailable: self = .unavailableStore
    case .missingInstance: self = .notFound
    case .duplicateName: self = .duplicateName
    case .defaultInvariant: self = .defaultReplacementRequired
    case .changedInstance: self = .changed
    case .invalidInstance: self = .invalidAuthentication
    }
  }

  var code: String {
    switch self {
    case .usage: "invalid_usage"
    case .invalidStore: "invalid_kaiba_instance_store"
    case .unavailableStore: "kaiba_instance_store_unavailable"
    case .notFound: "kaiba_instance_not_found"
    case .duplicateName: "duplicate_kaiba_instance_name"
    case .invalidName: "invalid_kaiba_instance_name"
    case .invalidEndpoint: "invalid_endpoint"
    case .invalidAuthentication: "invalid_authentication_policy"
    case .defaultReplacementRequired: "default_replacement_required"
    case .bindingScanFailed: "kaiba_binding_scan_failed"
    case .instanceInUse: "kaiba_instance_in_use"
    case .disabled: "disabled_kaiba_instance"
    case .missingCredential: "missing_kaiba_credential"
    case .changed: "kaiba_instance_changed"
    case .authFailed: "auth_failed"
    case .connectionFailed: "connection_failed"
    case .incompatible: "incompatible_kaiba_instance"
    }
  }

  var exitCode: CLIExitCode {
    switch self {
    case .unavailableStore, .bindingScanFailed, .changed, .authFailed, .connectionFailed, .incompatible: .failure
    default: .usage
    }
  }

  var message: String {
    switch self {
    case .usage: "The command arguments are invalid."
    case .invalidStore: "The Kaiba instance catalog is invalid."
    case .unavailableStore: "The Kaiba instance catalog could not be accessed."
    case .notFound: "No Kaiba instance matches the selector."
    case .duplicateName: "A Kaiba instance already uses that name."
    case .invalidName: "The Kaiba instance name is invalid."
    case .invalidEndpoint: "The Kaiba endpoint is invalid."
    case .invalidAuthentication: "The Kaiba authentication policy is invalid."
    case .defaultReplacementRequired: "The current default cannot be disabled or removed."
    case .bindingScanFailed: "Kaiba binding references could not be inspected safely."
    case .instanceInUse: "The Kaiba instance is still bound to workflow nodes."
    case .disabled: "The Kaiba instance is disabled."
    case .missingCredential: "The configured bearer environment variable is unavailable."
    case .changed: "The Kaiba instance changed while the test was running."
    case .authFailed: "Kaiba rejected authentication."
    case .connectionFailed: "The Kaiba endpoint could not be reached."
    case .incompatible: "The endpoint did not provide a compatible Kaiba API."
    }
  }

  var nextAction: String {
    switch self {
    case .usage: "Run riela kaiba instance --help."
    case .invalidStore: "Repair the catalog schema and default invariant."
    case .unavailableStore: "Check the Riela home directory permissions and retry."
    case .notFound: "Run riela kaiba instance list and use an existing name or ID."
    case .duplicateName: "Choose a unique instance name."
    case .invalidName: "Use a 1 to 80 character name without control characters."
    case .invalidEndpoint: "Use an HTTP(S) server root or /graphql URL without credentials, query, or fragment."
    case .invalidAuthentication: "Choose one authentication mode and its required explicit transport opt-ins."
    case .defaultReplacementRequired: "Set another enabled instance as default first."
    case .bindingScanFailed: "Repair or remove the unreadable workflow state and retry."
    case .instanceInUse: "Update the bindings or repeat remove with --force."
    case .disabled: "Enable the instance before testing or making it default."
    case .missingCredential: "Export the configured environment variable and retry."
    case .changed: "Test the current instance configuration again."
    case .authFailed: "Verify the configured credential and server authorization."
    case .connectionFailed: "Verify the endpoint, network, and server availability."
    case .incompatible: "Update Kaiba or select a compatible instance."
    }
  }
}

private struct KaibaInstanceDTO: Encodable {
  let id: String
  let name: String
  let endpoint: String
  let authenticationMode: String
  let credentialEnvironmentVariable: String?
  let enabled: Bool
  let isDefault: Bool
  let allowInsecureHTTP: Bool
  let allowRemoteUnauthenticated: Bool
  let lastTest: KaibaLastTestDTO

  init(_ instance: KaibaInstance) {
    id = instance.id
    name = instance.name
    endpoint = instance.endpoint
    authenticationMode = instance.authentication.credentialEnvironmentVariable == nil ? "unauthenticated" : "bearer"
    credentialEnvironmentVariable = instance.authentication.credentialEnvironmentVariable
    enabled = instance.enabled
    isDefault = instance.isDefault
    allowInsecureHTTP = instance.allowInsecureHTTP
    allowRemoteUnauthenticated = instance.allowRemoteUnauthenticated
    lastTest = KaibaLastTestDTO(instance.lastTest)
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, endpoint, authenticationMode, credentialEnvironmentVariable
    case enabled, isDefault, allowInsecureHTTP, allowRemoteUnauthenticated, lastTest
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(endpoint, forKey: .endpoint)
    try container.encode(authenticationMode, forKey: .authenticationMode)
    try container.encode(credentialEnvironmentVariable, forKey: .credentialEnvironmentVariable)
    try container.encode(enabled, forKey: .enabled)
    try container.encode(isDefault, forKey: .isDefault)
    try container.encode(allowInsecureHTTP, forKey: .allowInsecureHTTP)
    try container.encode(allowRemoteUnauthenticated, forKey: .allowRemoteUnauthenticated)
    try container.encode(lastTest, forKey: .lastTest)
  }
}

private struct KaibaLastTestDTO: Encodable {
  let status: String
  let code: String?
  let attemptedAt: Date?

  init(_ value: KaibaInstanceLastTest) {
    status = value.status.rawValue
    code = value.code
    attemptedAt = value.attemptedAt
  }
}

private struct KaibaSuccessDTO: Encodable {
  let status = "ok"
  let operation: String
  let instance: KaibaInstanceDTO?
  let instances: [KaibaInstanceDTO]?

  init(operation: String, instance: KaibaInstance?, instances: [KaibaInstance]?) {
    self.operation = operation
    self.instance = instance.map(KaibaInstanceDTO.init)
    self.instances = instances?.map(KaibaInstanceDTO.init)
  }

  private enum CodingKeys: String, CodingKey { case status, operation, instance, instances }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(status, forKey: .status)
    try container.encode(operation, forKey: .operation)
    try container.encodeIfPresent(instance, forKey: .instance)
    try container.encodeIfPresent(instances, forKey: .instances)
  }
}

private struct KaibaRemovalSuccessDTO: Encodable {
  let status = "ok"
  let operation = "remove"
  let instance: KaibaInstanceDTO
  let affectedReferences: [KaibaBindingReference]

  init(instance: KaibaInstance, references: [KaibaBindingReference]) {
    self.instance = KaibaInstanceDTO(instance)
    affectedReferences = references
  }
}

private struct KaibaFailureDTO: Encodable {
  let status = "error"
  let operation: String
  let code: String
  let message: String
  let nextAction: String
  let instanceId: String?
  let instanceName: String?

  init(operation: String, failure: KaibaCommandFailure, instance: KaibaInstance?) {
    self.operation = operation
    code = failure.code
    message = failure.message
    nextAction = failure.nextAction
    instanceId = instance?.id
    instanceName = instance?.name
  }

  private enum CodingKeys: String, CodingKey {
    case status, operation, code, message, nextAction, instanceId, instanceName
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(status, forKey: .status)
    try container.encode(operation, forKey: .operation)
    try container.encode(code, forKey: .code)
    try container.encode(message, forKey: .message)
    try container.encode(nextAction, forKey: .nextAction)
    try container.encodeIfPresent(instanceId, forKey: .instanceId)
    try container.encodeIfPresent(instanceName, forKey: .instanceName)
  }
}
