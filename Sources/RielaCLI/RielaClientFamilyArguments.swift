import ArgumentParser
import Foundation

protocol RielaClientFamilyArguments: ParsableArguments {}

extension RielaClientFamilyArguments {
  static func parseCLI(_ arguments: [String]) throws -> Self {
    do {
      return try Self.parse(arguments)
    } catch {
      throw CLIUsageError(Self.message(for: error))
    }
  }
}

enum WorkflowClientSubcommand: String, ExpressibleByArgument {
  case package
  case manifest
  case list
  case status
  case register
  case versions
  case version
  case restore
  case validate
  case inspect
  case usage
  case run
  case checkout
  case create
  case selfImprove = "self-improve"
}

enum SessionClientSubcommand: String, ExpressibleByArgument {
  case rerun
  case resume
  case list
  case latest
  case progress
  case health
  case status
  case continueSession = "continue"
  case stepRuns = "step-runs"
  case export
  case logs
}

enum InstanceClientSubcommand: String, ExpressibleByArgument {
  case list
  case show
  case create
  case update
  case remove
}

enum SetupClientSubcommand: String, ExpressibleByArgument {
  case container
}

enum WorkflowManifestClientSubcommand: String, ExpressibleByArgument {
  case validate
}

enum WorkflowVersionClientOperation: String, ExpressibleByArgument {
  case show
  case diff
}

enum LoopBaselineAction: String, ExpressibleByArgument {
  case set
  case show
  case clear
}

enum PackageRegistryClientAction: String, CaseIterable, ExpressibleByArgument {
  case add
  case list
  case sync
  case index
}

enum NoteNotebookClientAction: String, CaseIterable, ExpressibleByArgument {
  case list
  case show
  case create
  case delete
}

enum NoteStorageClientAction: String, CaseIterable, ExpressibleByArgument {
  case migrate
  case gc
}

enum NoteClientRegistrationAction: String, CaseIterable, ExpressibleByArgument {
  case register
  case list
  case revoke
}

enum NoteAutoActionClientAction: String, CaseIterable, ExpressibleByArgument {
  case retry
}

enum GraphQLClientAction: String, CaseIterable, ExpressibleByArgument {
  case schema
  case execute
  case document
  case noteDocument = "note-document"
  case session
  case inspectSession = "inspect-session"
  case workflowSession = "workflow-session"
  case managerSession = "manager-session"
  case sendManagerMessage = "send-manager-message"
  case replayCommunication = "replay-communication"
  case retryCommunicationDelivery = "retry-communication-delivery"
  case retryCommunication = "retry-communication"
}

enum EventsClientAction: String, CaseIterable, ExpressibleByArgument {
  case validate
  case emit
  case list
  case replay
  case serve
  case replies
  case schedules
}

enum EventSchedulesClientAction: String, CaseIterable, ExpressibleByArgument {
  case list
  case inspect
  case cancel
}

enum HookClientVendor: String, CaseIterable, ExpressibleByArgument {
  case codex
  case claude
  case cursor
}

extension CaseIterable where Self: RawRepresentable, RawValue == String {
  static var allRawValues: [String] {
    allCases.map(\.rawValue)
  }
}

struct ParsedWorkflowFamily: RielaClientFamilyArguments {
  @Argument var subcommand: WorkflowClientSubcommand
  @Argument(parsing: .captureForPassthrough) var remainder: [String] = []
}

struct ParsedWorkflowRegisterArguments: RielaClientFamilyArguments {
  @Argument var inputPath: String
  @Flag var temporary = false
  @Flag var overwrite = false
  @Option(name: [.customLong("working-dir"), .customLong("working-directory")])
  var workingDirectory = FileManager.default.currentDirectoryPath
  @Option var output: WorkflowOutputFormat = .jsonl
}

struct ParsedPackageFamily: RielaClientFamilyArguments {
  @Argument var subcommand: PackageCommandKind
  @Argument(parsing: .captureForPassthrough) var remainder: [String] = []
}

struct ParsedNodeFamily: RielaClientFamilyArguments {
  @Argument var subcommand: NodeCommandKind
  @Argument(parsing: .captureForPassthrough) var remainder: [String] = []
}

struct ParsedLoopFamily: RielaClientFamilyArguments {
  @Argument var subcommand: LoopCommandKind
  @Argument(parsing: .captureForPassthrough) var remainder: [String] = []
}

struct ParsedMemoryFamily: RielaClientFamilyArguments {
  @Argument var subcommand: MemoryCommandKind
  @Argument(parsing: .captureForPassthrough) var remainder: [String] = []
}

struct ParsedNoteFamily: RielaClientFamilyArguments {
  @Argument var subcommand: NoteCommandKind
  @Argument(parsing: .captureForPassthrough) var remainder: [String] = []
}

struct ParsedSessionFamily: RielaClientFamilyArguments {
  @Argument var subcommand: SessionClientSubcommand
  @Argument(parsing: .captureForPassthrough) var remainder: [String] = []
}

struct ParsedInstanceFamily: RielaClientFamilyArguments {
  @Argument var subcommand: InstanceClientSubcommand
  @Argument(parsing: .captureForPassthrough) var remainder: [String] = []
}

struct ParsedSetupFamily: RielaClientFamilyArguments {
  @Argument var subcommand: SetupClientSubcommand
  @Argument(parsing: .captureForPassthrough) var remainder: [String] = []
}

struct ParsedWorkflowManifestFamily: RielaClientFamilyArguments {
  @Argument var subcommand: WorkflowManifestClientSubcommand
  @Argument(parsing: .captureForPassthrough) var remainder: [String] = []
}

struct ParsedWorkflowVersionsArguments: RielaClientFamilyArguments {
  @Argument var workflowName: String
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

struct ParsedWorkflowVersionFamily: RielaClientFamilyArguments {
  @Argument var operation: WorkflowVersionClientOperation
  @Argument(parsing: .captureForPassthrough) var remainder: [String] = []
}

struct ParsedWorkflowVersionShowArguments: RielaClientFamilyArguments {
  @Argument var workflowName: String
  @Argument var reference: String
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

struct ParsedWorkflowVersionDiffArguments: RielaClientFamilyArguments {
  @Argument var workflowName: String
  @Argument var firstReference: String
  @Argument var secondReference: String
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

struct ParsedWorkflowRestoreArguments: RielaClientFamilyArguments {
  @Argument var workflowName: String
  @Argument var snapshotId: String
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

struct ParsedTargetAndOptions {
  var target: String?
  var options: [String]

  static func parseCLI(_ arguments: [String]) throws -> Self {
    if let parsed = try? ParsedRequiredTargetAndOptions.parseCLI(arguments) {
      return Self(target: parsed.target, options: parsed.options)
    }
    let parsed = try ParsedPassthroughArguments.parseCLI(arguments)
    return Self(target: nil, options: parsed.options)
  }
}

private struct ParsedRequiredTargetAndOptions: RielaClientFamilyArguments {
  @Argument var target: String
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

private struct ParsedPassthroughArguments: RielaClientFamilyArguments {
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

struct ParsedScopedCommandArguments {
  var command: String?
  var target: String?
  var options: [String]

  static func parseCLI(_ arguments: [String]) throws -> Self {
    if let parsed = try? ParsedRequiredCommandTargetAndOptions.parseCLI(arguments) {
      return Self(command: parsed.command, target: parsed.target, options: parsed.options)
    }
    if let parsed = try? ParsedRequiredTargetAndOptions.parseCLI(arguments) {
      return Self(command: parsed.target, target: nil, options: parsed.options)
    }
    let parsed = try ParsedPassthroughArguments.parseCLI(arguments)
    return Self(command: nil, target: nil, options: parsed.options)
  }
}

private struct ParsedRequiredCommandTargetAndOptions: RielaClientFamilyArguments {
  @Argument var command: String
  @Argument var target: String
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

struct ParsedClientInvocation {
  var scope: String
  var command: String?
  var target: String?

  static func parseCLI(_ arguments: [String]) -> Self {
    if let parsed = try? ParsedThreePartInvocation.parseCLI(arguments) {
      return Self(scope: parsed.scope, command: parsed.command, target: parsed.target)
    }
    if let parsed = try? ParsedTwoPartInvocation.parseCLI(arguments) {
      return Self(scope: parsed.scope, command: parsed.command, target: nil)
    }
    if let parsed = try? ParsedRequiredTargetAndOptions.parseCLI(arguments) {
      return Self(scope: parsed.target, command: nil, target: nil)
    }
    return Self(scope: "riela", command: nil, target: nil)
  }
}

private struct ParsedThreePartInvocation: RielaClientFamilyArguments {
  @Argument var scope: String
  @Argument var command: String
  @Argument var target: String
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

private struct ParsedTwoPartInvocation: RielaClientFamilyArguments {
  @Argument var scope: String
  @Argument var command: String
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

struct ParsedWorkflowCallArguments: RielaClientFamilyArguments {
  @Argument var workflowId: String
  @Argument var workflowRunId: String
  @Argument var stepId: String
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

struct ParsedSessionRerunArguments: RielaClientFamilyArguments {
  @Argument var sessionId: String
  @Argument var stepId: String
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

struct ParsedSessionResumeArguments: RielaClientFamilyArguments {
  @Argument var sessionId: String
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

struct ParsedLoopBaselineRoute: RielaClientFamilyArguments {
  @Argument var action: LoopBaselineAction
  @Argument var workflowId: String
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

struct ParsedLoopBaselineDiffRoute: RielaClientFamilyArguments {
  @Flag var baseline = false
  @Argument var workflowId: String
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

struct ParsedLoopDiffRoute: RielaClientFamilyArguments {
  @Argument var firstSessionId: String
  @Argument var secondSessionId: String
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

struct ParsedLoopTargetRoute: RielaClientFamilyArguments {
  @Argument var target: String
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

struct ParsedLoopBaselineActionArguments: RielaClientFamilyArguments {
  @Argument var action: LoopBaselineAction
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

struct ParsedLoopBaselineMarker: RielaClientFamilyArguments {
  @Flag var baseline = false
  @Argument(parsing: .allUnrecognized) var options: [String] = []
}

struct ParsedPackageRegistryRoute: RielaClientFamilyArguments {
  @Argument var action: PackageRegistryClientAction
  @Argument(parsing: .captureForPassthrough) var remainder: [String] = []
}

struct ParsedNoteNotebookRoute: RielaClientFamilyArguments {
  @Argument var action: NoteNotebookClientAction
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

struct ParsedNoteStorageRoute: RielaClientFamilyArguments {
  @Argument var action: NoteStorageClientAction
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

struct ParsedNoteClientRegistrationRoute: RielaClientFamilyArguments {
  @Argument var action: NoteClientRegistrationAction
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

struct ParsedNoteAutoActionRoute: RielaClientFamilyArguments {
  @Argument var action: NoteAutoActionClientAction
  @Argument(parsing: .captureForPassthrough) var options: [String] = []
}

struct ParsedGraphQLActionRoute: RielaClientFamilyArguments {
  @Argument var action: GraphQLClientAction
  @Argument(parsing: .captureForPassthrough) var remainder: [String] = []
}

struct ParsedEventsActionRoute: RielaClientFamilyArguments {
  @Argument var action: EventsClientAction
  @Argument(parsing: .captureForPassthrough) var remainder: [String] = []
}

struct ParsedEventSchedulesRoute: RielaClientFamilyArguments {
  @Argument var eventsAction: EventsClientAction
  @Argument var action: EventSchedulesClientAction
  @Argument(parsing: .captureForPassthrough) var remainder: [String] = []
}

struct ParsedHookRoute: RielaClientFamilyArguments {
  @Argument var vendor: HookClientVendor
  @Argument(parsing: .captureForPassthrough) var remainder: [String] = []
}

extension PackageCommandKind: ExpressibleByArgument {}
extension NodeCommandKind: ExpressibleByArgument {}
extension LoopCommandKind: ExpressibleByArgument {}
extension MemoryCommandKind: ExpressibleByArgument {}
extension NoteCommandKind: ExpressibleByArgument {}
