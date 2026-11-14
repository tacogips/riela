import Foundation

public enum BuiltinAddonContainerOperation: String, Codable, Sendable {
  case execute
  case acknowledge
  case terminal
}

/// Runtime-issued identities travel unchanged; worker requests cannot mint them.
public struct BuiltinAddonContainerRequest: Codable, Equatable, Sendable {
  public static let currentVersion = 1
  public static let maximumRecordBytes = 64 * 1024 * 1024
  public var protocolVersion: Int
  public var operation: BuiltinAddonContainerOperation
  public var input: WorkflowAddonExecutionInput?
  public var finalizationToken: WorkflowAddonFinalizationToken?
  public var workflowExecutionId: String?
  public var stepExecutionIds: [String]?
  public var deadline: Date?
  public var nativeAppleBridgeDirectory: String?
  public var kaibaInstance: BuiltinAddonKaibaInstance?
  public var nativeKaibaBridgeDirectory: String?

  public init(
    operation: BuiltinAddonContainerOperation,
    input: WorkflowAddonExecutionInput? = nil,
    finalizationToken: WorkflowAddonFinalizationToken? = nil,
    workflowExecutionId: String? = nil,
    stepExecutionIds: [String]? = nil,
    deadline: Date? = nil,
    nativeAppleBridgeDirectory: String? = nil,
    kaibaInstance: BuiltinAddonKaibaInstance? = nil,
    nativeKaibaBridgeDirectory: String? = nil
  ) {
    protocolVersion = Self.currentVersion
    self.operation = operation
    self.input = input
    self.finalizationToken = finalizationToken
    self.workflowExecutionId = workflowExecutionId
    self.stepExecutionIds = stepExecutionIds
    self.deadline = deadline
    self.nativeAppleBridgeDirectory = nativeAppleBridgeDirectory
    self.kaibaInstance = kaibaInstance
    self.nativeKaibaBridgeDirectory = nativeKaibaBridgeDirectory
  }

  public func validate() throws {
    guard protocolVersion == Self.currentVersion else {
      throw AdapterExecutionError(.policyBlocked, "unsupported built-in container protocol version")
    }
    if let directory = nativeAppleBridgeDirectory {
      let url = URL(fileURLWithPath: directory)
      guard operation == .execute, directory.hasPrefix("/"), !directory.contains("\u{0}"),
            directory == url.standardizedFileURL.path, UUID(uuidString: url.lastPathComponent) != nil else { throw invalidRequest() }
    }
    if let kaibaInstance {
      guard operation == .execute, let input, input.addon.name.hasPrefix("kaiba/"),
            nativeAppleBridgeDirectory == nil,
            input.addon.config?["kaibaInstanceId"].map({ $0 == .string(kaibaInstance.id) }) ?? true else { throw invalidRequest() }
    }
    if let directory = nativeKaibaBridgeDirectory {
      let url = URL(fileURLWithPath: directory)
      guard operation == .execute, kaibaInstance != nil, nativeAppleBridgeDirectory == nil,
            directory.hasPrefix("/"), !directory.contains("\u{0}"), directory == url.standardizedFileURL.path,
            UUID(uuidString: url.lastPathComponent) != nil else { throw invalidRequest() }
    }
    switch operation {
    case .execute:
      guard let input, input.addon.container == nil, input.addon.sandbox == nil, finalizationToken == nil,
            workflowExecutionId == nil, stepExecutionIds == nil else { throw invalidRequest() }
    case .acknowledge:
      guard input == nil, let finalizationToken, !finalizationToken.value.isEmpty,
            workflowExecutionId == nil, stepExecutionIds == nil else { throw invalidRequest() }
    case .terminal:
      guard input == nil, finalizationToken == nil, let workflowExecutionId, !workflowExecutionId.isEmpty,
            let stepExecutionIds, stepExecutionIds.allSatisfy({ !$0.isEmpty }) else { throw invalidRequest() }
    }
  }

  private func invalidRequest() -> AdapterExecutionError {
    AdapterExecutionError(.policyBlocked, "invalid built-in container request for \(operation.rawValue)")
  }
}

public struct BuiltinAddonContainerFailure: Codable, Equatable, Sendable {
  public var code: AdapterExecutionErrorCode
  public var message: String
  public var isRetryable: Bool?
  public var retryAfterSeconds: Double?

  public init(_ error: AdapterExecutionError) {
    code = error.code
    message = error.message
    isRetryable = error.isRetryable
    retryAfterSeconds = error.retryAfter.map {
      Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18
    }
  }

  public func executionError() throws -> AdapterExecutionError {
    if let retryAfterSeconds, !retryAfterSeconds.isFinite || retryAfterSeconds < 0 || retryAfterSeconds >= Double(Int64.max) {
      throw AdapterExecutionError(.invalidOutput, "invalid container retry duration")
    }
    return AdapterExecutionError(code, message, isRetryable: isRetryable, retryAfter: retryAfterSeconds.map { .seconds($0) })
  }
}

/// The internal finalization token is explicitly carried outside the public
/// AdapterExecutionOutput JSON, which intentionally omits that token.
public struct BuiltinAddonContainerReply: Codable, Equatable, Sendable {
  public var protocolVersion: Int
  public var output: AdapterExecutionOutput?
  public var finalizationToken: WorkflowAddonFinalizationToken?
  public var failure: BuiltinAddonContainerFailure?

  public init(output: AdapterExecutionOutput? = nil, failure: BuiltinAddonContainerFailure? = nil) {
    protocolVersion = BuiltinAddonContainerRequest.currentVersion
    self.output = output
    finalizationToken = output?.runtimeFinalizationToken
    self.failure = failure
  }

  public func validatedOutput(for operation: BuiltinAddonContainerOperation) throws -> AdapterExecutionOutput? {
    guard protocolVersion == BuiltinAddonContainerRequest.currentVersion else {
      throw AdapterExecutionError(.invalidOutput, "unsupported built-in container reply version")
    }
    if let failure {
      guard output == nil, finalizationToken == nil else {
        throw AdapterExecutionError(.invalidOutput, "container reply contains both output and failure")
      }
      throw try failure.executionError()
    }
    if operation == .execute {
      guard var output else { throw AdapterExecutionError(.invalidOutput, "container reply is missing execution output") }
      output.runtimeFinalizationToken = finalizationToken
      return output
    }
    guard output == nil, finalizationToken == nil else {
      throw AdapterExecutionError(.invalidOutput, "container control reply contains unexpected output")
    }
    return nil
  }
}
