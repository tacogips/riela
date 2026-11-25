import ArgumentParser
import RielaCore

enum AskClientAction: String, CaseIterable {
  case list, show, cancel, confirm, dismiss, remove
}

struct AskCommandArguments: RielaClientFamilyArguments {
  @Option var conversation: String?
  @Option var session: String?
  @Option var bot: String?
  @Option var workflow: String?
  @Option var remote: String?
  @Option var provider: String?
  @Option var model: String?
  @Option var effort: String?
  @Flag var noFollow = false
  @Flag var follow = false
  @Option var output: String?
  @Option var sessionStore: String?
  @Option var scope: String?
  @Option var workingDir: String?
  @Argument var words: [String] = []

  func action(in raw: [String]) throws -> AskClientAction? {
    if let marker = raw.firstIndex(of: "--"),
       try Self.parseCLI(Array(raw[..<marker])).words.isEmpty { return nil }
    return words.first.flatMap(AskClientAction.init(rawValue:))
  }

  var context: AskContext? {
    if let session { return .init(kind: .session, id: session) }
    if let bot { return .init(kind: .bot, id: bot) }
    if let workflow { return .init(kind: .workflow, id: workflow) }
    return nil
  }

  var selection: AskSelection? {
    guard provider != nil || model != nil || effort != nil else { return nil }
    return .init(providerInstanceId: provider, model: model, effort: effort)
  }

  func validate(for action: AskClientAction?) throws {
    guard [session, bot, workflow].compactMap({ $0 }).count <= 1 else {
      throw CLIUsageError("ask accepts at most one of --session, --bot, or --workflow")
    }
    if follow, action != .show { throw CLIUsageError("--follow is only accepted by ask show") }
    if action != nil, context != nil || selection != nil || conversation != nil || noFollow {
      throw CLIUsageError("Ask message options require a message")
    }
    if conversation != nil, selection != nil {
      throw CLIUsageError("Choose a provider, model, or effort when starting a conversation")
    }
    let count: Int = switch action {
    case nil, .list: 1
    case .show, .cancel, .remove: 2
    case .confirm, .dismiss: 3
    }
    guard words.count == count else {
      let usage = action.map { "riela ask \($0.rawValue) --help" } ?? "riela ask --help"
      throw CLIUsageError("Invalid Ask arguments. See \(usage).")
    }
  }
}
