import Foundation
import RielaCore
import RielaGraphQL

struct AskCommands {
  var writer: (@Sendable (String) -> Void)?
  var transport: RemoteHTTP.Transport = RemoteHTTP.production

  func run(_ options: CLICommandOptions) async -> CLICommandResult {
    if options.arguments.first == AskToolServerArguments.verb {
      return await runToolServer(arguments: Array(options.arguments.dropFirst()))
    }
    do {
      let parsed = try AskCommandArguments.parseCLI(options.arguments)
      let action = try parsed.action(in: options.arguments)
      try parsed.validate(for: action)
      let output = try parseOutputValue(parsed.output ?? "text", allowTableOutput: false)
      guard output == .text || output == .json else { throw CLIUsageError("ask --output must be json or text") }
      guard let scope = WorkflowScope(rawValue: parsed.scope ?? "auto") else {
        throw CLIUsageError("ask --scope must be auto, project, or user")
      }
      let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
      let registry = RemoteRegistry(environment: environment)
      let target = try RemoteRouting.resolve(remote: parsed.remote, registry: registry)
      let selector = switch target {
      case .local: "local"
      case let .remote(record, _): record.name
      case .all: throw CLIUsageError("ask requires one host")
      }
      if selector == "local", parsed.noFollow {
        throw CLIUsageError("ask --no-follow needs --remote <name>; a local turn runs in this process")
      }
      let host = AskHost.local(
        workingDirectory: parsed.workingDir ?? FileManager.default.currentDirectoryPath,
        sessionStore: parsed.sessionStore, scope: scope, environment: environment
      )
      let provider = AskGraphQLProvider(service: AskService(host: host), registry: registry, transport: transport)
      return try await execute(action, args: parsed, output: output, selector: selector, provider: provider)
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch let error as AskError {
      return CLICommandResult(exitCode: .failure, stderr: error.description)
    } catch let error as BotStoreError {
      return CLICommandResult(exitCode: .failure, stderr: error.description)
    } catch is CancellationError {
      return CLICommandResult(exitCode: .failure, stderr: "ask_cancelled: Ask was cancelled")
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "ask_io_failure: Ask operation failed")
    }
  }

  private func execute(
    _ action: AskClientAction?, args: AskCommandArguments, output: WorkflowOutputFormat,
    selector: String, provider: AskGraphQLProvider
  ) async throws -> CLICommandResult {
    guard let action else {
      return try await send(args, output: output, selector: selector, provider: provider)
    }
    if action == .list {
      return try renderList(await provider.askConversations(remote: selector), output: output)
    }

    let id = args.words[1]
    let input = AskConversationInput(conversationId: id, remote: selector)
    switch action {
    case .show:
      let snapshot = try await provider.askConversation(conversationId: id, remote: selector)
      if args.follow {
        return try await follow(snapshot, output: output, selector: selector, provider: provider, ownsLocalTurn: false)
      }
      return try render(snapshot, output: output)
    case .cancel:
      return try render(await provider.cancelAsk(input: input), output: output)
    case .confirm, .dismiss:
      let decision = AskActionInput(conversationId: id, actionId: args.words[2], remote: selector)
      let snapshot = action == .confirm
        ? try await provider.confirmAskAction(input: decision)
        : try await provider.dismissAskAction(input: decision)
      let decided = snapshot.actions.first { $0.actionId == decision.actionId }
      let line = decided.map { "\($0.actionId) \($0.status.rawValue)\n" } ?? ""
      return try render(snapshot, output: output, content: line)
    case .remove:
      return try renderList(await provider.removeAskConversation(input: input), output: output)
    case .list:
      preconditionFailure("Ask list already handled")
    }
  }

  private func send(
    _ args: AskCommandArguments, output: WorkflowOutputFormat, selector: String, provider: AskGraphQLProvider
  ) async throws -> CLICommandResult {
    let snapshot: AskConversationPayload
    if let id = args.conversation {
      snapshot = try await provider.sendAskMessage(input: .init(
        conversationId: id, message: args.words[0], context: args.context, remote: selector
      ))
    } else {
      snapshot = try await provider.startAsk(input: .init(
        message: args.words[0], context: args.context, selection: args.selection, remote: selector
      ))
    }
    if args.noFollow { return try render(snapshot, output: output, content: "") }
    return try await follow(snapshot, output: output, selector: selector, provider: provider, ownsLocalTurn: selector == "local")
  }
}
