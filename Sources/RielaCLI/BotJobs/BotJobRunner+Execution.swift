import Foundation
import RielaCore
import RielaWorkflowRegistry

extension BotJobRunner {
  struct Execution {
    let sessionId: String?
    let succeeded: Bool
    let output: JSONObject
    let detail: String?
  }

  func execute(target: String, botId: String, sourceRef: String) async throws -> Execution {
    var command = WorkflowRunCommand()
    command.botLinkSource = ("job", sourceRef)
    command.botContextOverride = { context in
      var context = context
      context.permissionWaitMs = 0
      context.forceReadOnlySandbox = true
      return context
    }
    command.taskNodeAdapterOverride = nodeAdapter
    command.outputProjection = { result in
      [
        "sessionId": .string(result.session.sessionId),
        "rootOutput": .object(result.rootOutput ?? [:]),
        "detail": result.session.failureReason.map(JSONValue.string) ?? .null,
        "status": .string(result.status.rawValue)
      ]
    }
    var environment = service.environment
    environment["RIELA_API_KEY"] = ""
    if let memoryRoot { environment["RIELA_MEMORY_ROOT"] = memoryRoot }
    let options = WorkflowRunOptions(
      target: target, mockScenarioPath: mockScenarioPath, output: .json,
      maxSteps: 1, sessionStore: service.sessionStoreRoot, workingDirectory: service.workingDirectory,
      explicitWorkingDirectory: true, botId: botId
    )
    let result = await CLIRuntimeEnvironment.$captured.withValue(environment) {
      await CLIRuntimeEnvironment.$overrides.withValue(nil) {
        await command.run(options)
      }
    }
    let response = try JSONDecoder().decode(JSONObject.self, from: Data(result.stdout.utf8))
    let sessionId = response["sessionId"]?.stringValue
    let status = response["status"]?.stringValue
    let detail = response["detail"]?.stringValue ?? response["error"]?.stringValue ?? status
    let output: JSONObject
    if case let .object(payload)? = response["rootOutput"] { output = payload } else { output = [:] }
    return Execution(
      sessionId: sessionId, succeeded: result.exitCode == .success && status == WorkflowSessionStatus.completed.rawValue,
      output: output, detail: detail
    )
  }
}
