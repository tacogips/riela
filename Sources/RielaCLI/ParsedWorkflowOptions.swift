import Foundation

struct ParsedWorkflowOptions {
  var workflowDefinitionDir: String?
  var scope: WorkflowScope = .auto
  var output: WorkflowOutputFormat = .jsonl
  var executable = false
  var structure = false
  var variables: String?
  var nodePatch: String?
  var mockScenarioPath: String?
  var maxSteps: Int?
  var maxConcurrency: Int?
  var maxLoopIterations: Int?
  var defaultTimeoutMs: Int?
  var timeoutMs: Int?
  var artifactRoot: String?
  var sessionStore: String?
  var workingDirectory: String?
  var endpoint: String?
  var authToken: String?
  var authTokenEnv: String?
  var fromRegistry = false
  var nestedSuperviser = false
  var autoImprove = false
  var maxSupervisedAttempts = 3
  var maxWorkflowPatches = 2
  var monitorIntervalMs = 1_000
  var stallTimeoutMs = 30_000
  var stallDetectionEnabled = false
  var workflowMutationMode = WorkflowMutationMode.executionCopy

  init(_ tokens: [String], allowRunOptions: Bool = false, allowTableOutput: Bool = false) throws {
    var index = 0
    while index < tokens.count {
      let token = tokens[index]
      guard token.hasPrefix("--") else {
        throw CLIUsageError("unexpected positional argument '\(token)'")
      }
      try consumeOption(
        token,
        tokens: tokens,
        index: &index,
        allowRunOptions: allowRunOptions,
        allowTableOutput: allowTableOutput
      )
      index += 1
    }
    if stallTimeoutMs < monitorIntervalMs {
      throw CLIUsageError("invalid --auto-improve policy: stallTimeoutMs must be greater than or equal to monitorIntervalMs")
    }
  }

  private mutating func consumeOption(
    _ token: String,
    tokens: [String],
    index: inout Int,
    allowRunOptions: Bool,
    allowTableOutput: Bool
  ) throws {
    if try consumeCoreOption(token, tokens: tokens, index: &index, allowTableOutput: allowTableOutput) {
      return
    }
    if try consumeStringOption(token, tokens: tokens, index: &index, allowRunOptions: allowRunOptions) {
      return
    }
    if try consumeLimitOption(token, tokens: tokens, index: &index, allowRunOptions: allowRunOptions) {
      return
    }
    if try consumeAutoImproveOption(token, tokens: tokens, index: &index, allowRunOptions: allowRunOptions) {
      return
    }
    throw CLIUsageError("unknown option '\(token)'")
  }

  private mutating func consumeCoreOption(
    _ token: String,
    tokens: [String],
    index: inout Int,
    allowTableOutput: Bool
  ) throws -> Bool {
    switch token {
    case "--workflow-definition-dir":
      workflowDefinitionDir = try readOptionValue(token, tokens: tokens, index: &index)
    case "--scope":
      let raw = try readOptionValue(token, tokens: tokens, index: &index)
      guard let value = WorkflowScope(rawValue: raw), value != .direct else {
        throw CLIUsageError("invalid --scope value '\(raw)'; expected auto, project, or user")
      }
      scope = value
    case "--output":
      let raw = try readOptionValue(token, tokens: tokens, index: &index)
      guard let value = WorkflowOutputFormat(rawValue: raw) else {
        throw CLIUsageError("invalid --output value '\(raw)'; expected text, json, jsonl, or table")
      }
      if value == .table && !allowTableOutput {
        throw CLIUsageError("`--output table` is only supported for workflow list, workflow status, package search, and package list")
      }
      output = value
    case "--executable":
      executable = true
    case "--structure":
      structure = true
    case "--from-registry":
      fromRegistry = true
    case "--nested-superviser", "--nested-supervisor":
      nestedSuperviser = true
    default:
      return false
    }
    return true
  }

  private mutating func consumeStringOption(
    _ token: String,
    tokens: [String],
    index: inout Int,
    allowRunOptions: Bool
  ) throws -> Bool {
    switch token {
    case "--node-patch":
      nodePatch = try readOptionValue(token, tokens: tokens, index: &index)
    case "--variables":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      variables = try readOptionValue(token, tokens: tokens, index: &index)
    case "--mock-scenario":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      mockScenarioPath = try readOptionValue(token, tokens: tokens, index: &index)
    case "--artifact-root":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      artifactRoot = try readOptionValue(token, tokens: tokens, index: &index)
    case "--session-store":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      sessionStore = try readOptionValue(token, tokens: tokens, index: &index)
    case "--working-dir", "--working-directory":
      workingDirectory = try readOptionValue(token, tokens: tokens, index: &index)
    case "--endpoint":
      endpoint = try readOptionValue(token, tokens: tokens, index: &index)
    case "--auth-token":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      authToken = try readOptionValue(token, tokens: tokens, index: &index)
    case "--auth-token-env":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      authTokenEnv = try readOptionValue(token, tokens: tokens, index: &index)
    default:
      return false
    }
    return true
  }

  private mutating func consumeLimitOption(
    _ token: String,
    tokens: [String],
    index: inout Int,
    allowRunOptions: Bool
  ) throws -> Bool {
    switch token {
    case "--max-steps":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      maxSteps = try positiveInt(token, readOptionValue(token, tokens: tokens, index: &index))
    case "--max-concurrency":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      maxConcurrency = try positiveInt(token, readOptionValue(token, tokens: tokens, index: &index))
    case "--max-loop-iterations":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      maxLoopIterations = try positiveInt(token, readOptionValue(token, tokens: tokens, index: &index))
    case "--default-timeout-ms":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      defaultTimeoutMs = try positiveInt(token, readOptionValue(token, tokens: tokens, index: &index))
    case "--timeout-ms":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      timeoutMs = try positiveInt(token, readOptionValue(token, tokens: tokens, index: &index))
    default:
      return false
    }
    return true
  }

  private mutating func consumeAutoImproveOption(
    _ token: String,
    tokens: [String],
    index: inout Int,
    allowRunOptions: Bool
  ) throws -> Bool {
    switch token {
    case "--auto-improve":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      autoImprove = true
    case "--no-auto-improve":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      autoImprove = false
      maxWorkflowPatches = 0
    case "--max-supervised-attempts":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      maxSupervisedAttempts = try positiveInt(token, readOptionValue(token, tokens: tokens, index: &index))
    case "--max-workflow-patches":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      maxWorkflowPatches = try nonNegativeInt(token, readOptionValue(token, tokens: tokens, index: &index))
    case "--monitor-interval-ms":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      monitorIntervalMs = try positiveInt(token, readOptionValue(token, tokens: tokens, index: &index))
    case "--stall-timeout-ms":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      stallTimeoutMs = try positiveInt(token, readOptionValue(token, tokens: tokens, index: &index))
      stallDetectionEnabled = true
    case "--workflow-mutation-mode":
      try requireRunOption(token, allowRunOptions: allowRunOptions)
      let rawMode = try readOptionValue(token, tokens: tokens, index: &index)
      guard let mode = WorkflowMutationMode(rawValue: rawMode) else {
        throw CLIUsageError("invalid --workflow-mutation-mode value '\(rawMode)'; expected \(WorkflowMutationMode.acceptedValuesDescription)")
      }
      workflowMutationMode = mode
    default:
      return false
    }
    return true
  }

  var autoImprovePolicy: WorkflowAutoImprovePolicy {
    WorkflowAutoImprovePolicy(
      maxSupervisedAttempts: maxSupervisedAttempts,
      maxWorkflowPatches: maxWorkflowPatches,
      monitorIntervalMs: monitorIntervalMs,
      stallTimeoutMs: stallTimeoutMs,
      stallDetectionEnabled: stallDetectionEnabled,
      workflowMutationMode: workflowMutationMode,
      nestedSuperviser: nestedSuperviser
    )
  }
}
