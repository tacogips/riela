import Foundation
import RielaAddonSupport
import RielaCore

enum BuiltinGitAddon: String {
  case commit = "riela/git-commit"
  case push = "riela/git-push"
}

extension BuiltinWorkflowAddonResolver: WorkflowAddonFinalizationAcknowledging,
  WorkflowAddonTerminalRecording {
  func executeGitAddon(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinGitAddon,
    deadline: Date?
  ) throws -> AdapterExecutionOutput {
    guard input.addon.version == "1" else {
      throw policyError("unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    guard let executionIdentity = input.executionIdentity,
          !executionIdentity.workflowExecutionId.isEmpty,
          !executionIdentity.stepExecutionId.isEmpty,
          executionIdentity.attempt > 0 else {
      throw policyError("mutating git add-ons require runtime-owned execution identity")
    }
    do {
      return try GitCommandRuntimeContext.$deadline.withValue(deadline) {
        switch operation {
        case .commit:
          return try executeGitCommit(input, identity: executionIdentity)
        case .push:
          return try executeGitPush(input, identity: executionIdentity)
        }
      }
    } catch let adapterError as AdapterExecutionError {
      throw adapterError
    } catch {
      throw AdapterExecutionError(
        .providerError,
        "git finalization failed before producing safe diagnostics",
        isRetryable: true
      )
    }
  }

  public func acknowledgeAcceptedFinalization(_ token: WorkflowAddonFinalizationToken) async throws {
    try gitFinalizationStore.acknowledge(token)
  }

  public func recordTerminalFinalization(
    workflowExecutionId: String,
    stepExecutionIds: [String]
  ) async throws {
    let repository = try loadGitRepository()
    try gitFinalizationStore.prepare(repositoryRoot: repository.root)
    try gitFinalizationStore.recordTerminalWorkflowExecution(
      workflowExecutionId,
      stepExecutionIds: stepExecutionIds,
      repository: repository.identity
    )
  }

  func renderedCommitMessage(_ value: JSONValue?, variables: JSONObject) throws -> String {
    guard case let .string(template) = value else {
      throw policyError("riela/git-commit config.commitMessageTemplate is required")
    }
    let rendered = renderJSONTemplates(.string(template), variables: variables)
    guard case let .string(message) = rendered else {
      throw policyError("riela/git-commit commit message must resolve to a string")
    }
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 4_096, !trimmed.contains("\0") else {
      throw policyError("riela/git-commit commit message is empty or invalid")
    }
    return trimmed
  }

  func renderedCommittedFiles(_ value: JSONValue?, variables: JSONObject) throws -> [String] {
    guard case let .string(template) = value else {
      throw policyError("riela/git-commit config.committedFilesTemplate is required")
    }
    let rendered = renderJSONTemplates(.string(template), variables: variables)
    guard case let .array(values) = rendered, !values.isEmpty, values.count <= 2_048 else {
      throw policyError("riela/git-commit committed files must resolve to a non-empty array")
    }
    var seen = Set<String>()
    return try values.map { value in
      guard case let .string(path) = value else {
        throw policyError("riela/git-commit committed file entries must be strings")
      }
      try validateRepositoryRelativePath(path)
      guard seen.insert(path).inserted else {
        throw policyError("riela/git-commit committed files must not contain duplicates")
      }
      return path
    }
  }

  func commitOutput(
    status: String,
    revision: String,
    message: String,
    files: [String],
    token: WorkflowAddonFinalizationToken
  ) -> AdapterExecutionOutput {
    AdapterExecutionOutput(
      provider: "riela-builtin-addon",
      model: "riela/git-commit@1",
      promptText: "",
      completionPassed: true,
      payload: [
        "git": .object([
          "operation": .string("commit"),
          "status": .string(status),
          "commitHash": .string(revision),
          "commitMessage": .string(message),
          "committedFiles": .array(files.map(JSONValue.string))
        ])
      ],
      runtimeFinalizationToken: token
    )
  }

  func pushOutput(status: String, revision: String, remote: String, branch: String) -> AdapterExecutionOutput {
    AdapterExecutionOutput(
      provider: "riela-builtin-addon",
      model: "riela/git-push@1",
      promptText: "",
      completionPassed: true,
      payload: [
        "git": .object([
          "operation": .string("push"),
          "status": .string(status),
          "commitHash": .string(revision),
          "pushedRemote": .string(remote),
          "pushedBranch": .string(branch)
        ])
      ]
    )
  }
}
