#if os(macOS)
import Foundation
import CodexAgent
import ClaudeCodeAgent
import CursorCLIAgent
import RielaAdapters
import RielaAppSupport
import RielaCore

extension RielaApp {
  func saveAssistantAssistance(_ assistance: String) -> String? {
    daemonState.assistant.assistance = assistance
    guard saveDaemonState() else {
      return status
    }
    status = "Updated assistant assistance"
    refreshDaemonWorkflowWindow()
    return nil
  }

  func saveAssistantSettings(_ settings: RielaAppAssistantSettings) -> String? {
    daemonState.assistant = settings
    guard saveDaemonState() else {
      return status
    }
    status = "Updated assistant settings"
    refreshDaemonWorkflowWindow()
    return nil
  }

  func submitAssistantMessage(_ message: String, workingDirectory: String?) {
    let prompt = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
      return
    }
    let resolvedWorkingDirectory = normalizedAssistantWorkingDirectory(workingDirectory)
    daemonState.assistant.appendMessage(role: .user, content: prompt)
    guard saveDaemonState() else {
      refreshDaemonWorkflowWindow()
      return
    }
    status = "Assistant running in \(resolvedWorkingDirectory)"
    refreshDaemonWorkflowWindow()
    let settings = daemonState.assistant
    Task { @MainActor in
      let reply = await runAssistantAgent(
        settings: settings,
        message: prompt,
        workingDirectory: resolvedWorkingDirectory
      )
      daemonState.assistant.appendMessage(role: .assistant, content: reply)
      _ = saveDaemonState()
      status = "Assistant replied"
      refreshDaemonWorkflowWindow()
    }
  }

  private func normalizedAssistantWorkingDirectory(_ workingDirectory: String?) -> String {
    if let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
      !workingDirectory.isEmpty {
      return URL(fileURLWithPath: workingDirectory, isDirectory: true).standardizedFileURL.path
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .standardizedFileURL.path
  }

  private func runAssistantAgent(
    settings: RielaAppAssistantSettings,
    message: String,
    workingDirectory: String
  ) async -> String {
    do {
      let vendor = try resolvedAssistantVendor(settings.vendor)
      let output = try await assistantAdapter(for: vendor).execute(
        assistantInput(settings: settings, vendor: vendor, message: message, workingDirectory: workingDirectory),
        context: AdapterExecutionContext(deadline: Date().addingTimeInterval(120))
      )
      return assistantReplyText(from: output)
    } catch let error as AdapterExecutionError {
      return "Assistant error: \(error.message)"
    } catch {
      return "Assistant error: \(error.localizedDescription)"
    }
  }

  private func resolvedAssistantVendor(_ vendor: RielaAppAssistantVendor) throws -> RielaAppAssistantVendor {
    if vendor != .automatic {
      return vendor
    }
    if executablePath(named: "codex") != nil {
      return .codexCLI
    }
    if executablePath(named: "claude") != nil {
      return .claudeCodeCLI
    }
    if executablePath(named: "cursor-agent") != nil {
      return .cursorCLI
    }
    let environment = ProcessInfo.processInfo.environment
    if environment["OPENAI_API_KEY"]?.isEmpty == false {
      return .openAIAPI
    }
    if environment["ANTHROPIC_API_KEY"]?.isEmpty == false || environment["CLAUDE_API_KEY"]?.isEmpty == false {
      return .anthropicAPI
    }
    if environment["CURSOR_API_KEY"]?.isEmpty == false {
      return .cursorAPI
    }
    throw AdapterExecutionError(.policyBlocked, "No assistant agent is available. Install codex/claude/cursor-agent or set OPENAI_API_KEY, ANTHROPIC_API_KEY, or CURSOR_API_KEY.")
  }

  private func assistantAdapter(for vendor: RielaAppAssistantVendor) throws -> any NodeAdapter {
    switch vendor {
    case .automatic:
      return try assistantAdapter(for: resolvedAssistantVendor(vendor))
    case .codexCLI:
      return CodexAgentAdapter()
    case .claudeCodeCLI:
      return ClaudeCodeAgentAdapter()
    case .cursorCLI:
      return CursorCLIAgentAdapter()
    case .openAIAPI:
      return OpenAiSDKAdapter()
    case .anthropicAPI:
      return AnthropicSDKAdapter()
    case .cursorAPI:
      return CursorSDKAdapter()
    }
  }

  private func assistantInput(
    settings: RielaAppAssistantSettings,
    vendor: RielaAppAssistantVendor,
    message: String,
    workingDirectory: String
  ) -> AdapterExecutionInput {
    AdapterExecutionInput(
      node: AgentNodePayload(
        id: "riela-app-assistant",
        executionBackend: assistantExecutionBackend(for: vendor),
        model: settings.normalizedModel,
        workingDirectory: workingDirectory
      ),
      promptText: assistantPrompt(message: message, settings: settings, workingDirectory: workingDirectory),
      systemPromptText: assistantSystemPrompt(workingDirectory: workingDirectory),
      agentEnvironment: assistantAgentEnvironment(vendor: vendor, workingDirectory: workingDirectory)
    )
  }

  private func assistantAgentEnvironment(
    vendor: RielaAppAssistantVendor,
    workingDirectory: String
  ) -> [String: String] {
    guard vendor == .cursorAPI else {
      return [:]
    }
    let environment = ProcessInfo.processInfo.environment
    return [
      "CURSOR_REPOSITORY_URL": environment["CURSOR_REPOSITORY_URL"] ?? gitValue(
        arguments: ["config", "--get", "remote.origin.url"],
        workingDirectory: workingDirectory
      ),
      "CURSOR_STARTING_REF": environment["CURSOR_STARTING_REF"] ?? gitValue(
        arguments: ["branch", "--show-current"],
        workingDirectory: workingDirectory
      ),
      "CURSOR_AUTO_CREATE_PR": environment["CURSOR_AUTO_CREATE_PR"] ?? "false",
      "CURSOR_WORK_ON_CURRENT_BRANCH": environment["CURSOR_WORK_ON_CURRENT_BRANCH"] ?? "true"
    ].compactMapValues { value in
      let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return trimmed.isEmpty ? nil : trimmed
    }
  }

  private func assistantExecutionBackend(for vendor: RielaAppAssistantVendor) -> NodeExecutionBackend {
    switch vendor {
    case .automatic, .codexCLI:
      .codexAgent
    case .claudeCodeCLI:
      .claudeCodeAgent
    case .cursorCLI:
      .cursorCliAgent
    case .openAIAPI:
      .officialOpenAISDK
    case .anthropicAPI:
      .officialAnthropicSDK
    case .cursorAPI:
      .officialCursorSDK
    }
  }

  private func assistantSystemPrompt(workingDirectory: String) -> String {
    [
      "You are the Riela Setup Assistant inside RielaApp.",
      "Your primary job is to help users set up Riela and create or configure Riela workflow instances in RielaApp.",
      "Only work for the active RielaApp profile named '\(daemonProfileName.rawValue)'.",
      "Treat '\(workingDirectory)' as the only allowed working directory.",
      "Do not suggest or perform file operations outside that directory or this profile's workflow/package state.",
      "Use the current profile instances as source of truth. Distinguish creating a new instance from editing an existing one.",
      "For instance creation, identify the workflow/package, display name or id, working directory, required environment values, event sources, and auto-start preference.",
      "If required information is missing, ask concise follow-up questions. Otherwise give exact RielaApp actions or riela CLI commands.",
      "Never invent configured secrets or claim that an instance exists unless it is present in the provided context.",
      "After creation guidance, include a validation or first-run check and the next fix for missing environment values.",
      "Reply in the user's language and prefer concrete Riela instance steps over general coding advice."
    ].joined(separator: "\n")
  }

  private func assistantPrompt(
    message: String,
    settings: RielaAppAssistantSettings,
    workingDirectory: String
  ) -> String {
    let instances = daemonInstances.map { instance in
      "- \(instance.id): \(instance.displayName), workflow \(instance.candidate.workflowId), cwd \(instance.preference.workingDirectory ?? instance.candidate.workingDirectory)"
    }.joined(separator: "\n")
    let history = settings.messages.suffix(12).map {
      "\($0.role.label): \($0.content)"
    }.joined(separator: "\n")
    return [
      settings.normalizedAssistance.isEmpty ? nil : "Profile assistance:\n\(settings.normalizedAssistance)",
      instances.isEmpty ? "No workflow instances are configured in this profile." : "Current profile instances:\n\(instances)",
      "Current working directory: \(workingDirectory)",
      history.isEmpty ? nil : "Recent chat:\n\(history)",
      "User request:\n\(message)"
    ].compactMap { $0 }.joined(separator: "\n\n")
  }

  private func assistantReplyText(from output: AdapterExecutionOutput) -> String {
    if case let .string(text) = output.payload["text"], !text.isEmpty {
      return text
    }
    if case let .string(text) = output.payload["replyText"], !text.isEmpty {
      return text
    }
    if case let .string(text) = output.payload["summary"], !text.isEmpty {
      return text
    }
    return "Assistant finished without a text response."
  }

  private func executablePath(named name: String) -> String? {
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin")
      .split(separator: ":")
      .map(String.init)
    return paths
      .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name).path }
      .first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  private func gitValue(arguments: [String], workingDirectory: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
    } catch {
      return nil
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      return nil
    }
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
  }
}
#endif
