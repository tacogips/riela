import ArgumentParser
import Foundation
import RielaCore

/// One command path the CLI actually accepts, derived from the router's
/// subcommand list and the typed family enums rather than from a hand-kept
/// list. Adding an enum case changes this enumeration immediately, so the CLI
/// gate fails until `SurfaceCatalog` gains the matching row.
public struct CLICommandDescriptor: Hashable, Sendable {
  public var path: [String]

  public init(_ path: [String]) {
    self.path = path
  }

  public var command: String { path.joined(separator: " ") }
}

public enum CLISurfaceEnumerator {
  /// Every command path `riela` accepts.
  public static func commands() -> [CLICommandDescriptor] {
    var descriptors: [CLICommandDescriptor] = []
    for route in routerCommandNames() {
      descriptors.append(contentsOf: expand(route: route))
    }
    // `auth` and `worker` are dispatched in `RielaCLIApplication.runParsed`
    // ahead of the argument parser, so the router does not list them.
    descriptors.append(contentsOf: PasskeyClientAction.allRawValues.map { CLICommandDescriptor(["auth", $0]) })
    descriptors.append(CLICommandDescriptor(["worker"]))
    descriptors.append(contentsOf: DistributedWorkerClientAction.allRawValues.map {
      CLICommandDescriptor(["worker", $0])
    })
    return descriptors
  }

  /// Command names registered on the argument-parser router. Help text is
  /// rendered from the same configuration, so help cannot list a command the
  /// router lacks.
  static func routerCommandNames() -> [String] {
    RielaClientCommandRouter.configuration.subcommands.compactMap { $0.configuration.commandName }
  }

  private static func expand(route: String) -> [CLICommandDescriptor] {
    func nested(_ values: [String]) -> [CLICommandDescriptor] {
      values.map { CLICommandDescriptor([route, $0]) }
    }
    switch route {
    case "workflow":
      return WorkflowClientSubcommand.allCases.flatMap { subcommand -> [CLICommandDescriptor] in
        switch subcommand {
        case .manifest:
          return WorkflowManifestClientSubcommand.allRawValues.map {
            CLICommandDescriptor([route, subcommand.rawValue, $0])
          }
        default:
          // `workflow package` delegates to the package family, which is
          // enumerated under its own route.
          return [CLICommandDescriptor([route, subcommand.rawValue])]
        }
      }
    case "package":
      return nested(PackageCommandKind.allRawValues)
    case "node":
      return nested(NodeCommandKind.allRawValues)
    case "setup":
      return nested(SetupClientSubcommand.allRawValues)
    case "kaiba":
      return KaibaInstanceClientAction.allRawValues.map { CLICommandDescriptor([route, "instance", $0]) }
    case "memory":
      return nested(MemoryCommandKind.allRawValues)
    case "instance":
      return nested(InstanceClientSubcommand.allRawValues)
    case "specialist":
      return nested(SpecialistCommandKind.allRawValues)
    case "session":
      return nested(SessionClientSubcommand.allRawValues)
    case "loop":
      return nested(LoopCommandKind.allRawValues)
    case "task":
      return nested(TaskCommandKind.allRawValues)
    case "graphql":
      return nested(GraphQLClientAction.allRawValues)
    case "hook":
      return nested(HookClientVendor.allRawValues)
    case "events":
      return EventsClientAction.allCases.flatMap { action -> [CLICommandDescriptor] in
        guard action == .schedules else { return [CLICommandDescriptor([route, action.rawValue])] }
        return EventSchedulesClientAction.allRawValues.map {
          CLICommandDescriptor([route, action.rawValue, $0])
        }
      }
    case "routine":
      return nested(RoutineClientAction.allRawValues)
    case "serve":
      // Bare `riela serve` is the long-running host; the named actions are
      // one-shot probes of the same server contract.
      return [CLICommandDescriptor([route])] + nested(ServeClientAction.allRawValues)
    case _ where leafRoutes.contains(route):
      return [CLICommandDescriptor([route])]
    default:
      // A route reaches here only if it was registered on the router without
      // being classified. `unclassifiedRoutes()` fails the CLI gate for it, so
      // a new family with nested actions cannot ship with its subcommands
      // invisible to the gate.
      return [CLICommandDescriptor([route])]
    }
  }

  /// Routes that are deliberately a single command with no subcommands.
  /// Everything else must have an expansion case above.
  static let leafRoutes: Set<String> = ["gql", "rrun", "doctor", "gc", "version", "call-step", "workflow-call"]

  /// Routes that are neither declared leaves nor expanded by `expand(route:)`.
  /// The CLI gate requires this to be empty: classifying a new family is what
  /// forces its subcommands into the catalog.
  public static func unclassifiedRoutes() -> [String] {
    routerCommandNames().filter { !leafRoutes.contains($0) && !expandedRoutes.contains($0) }
  }

  /// Routes `expand(route:)` knows how to walk into subcommands.
  static let expandedRoutes: Set<String> = [
    "workflow", "package", "node", "setup", "kaiba", "memory", "instance",
    "specialist", "session", "loop", "task", "graphql", "hook", "events", "routine", "serve"
  ]

  /// Every `--option` token any `riela` parser accepts, rendered from the
  /// argument-parser definitions themselves. The skill gate resolves
  /// documented flags against this set, so a renamed flag fails the test
  /// instead of misleading an agent.
  public static func optionNames() -> Set<String> {
    var names: Set<String> = ["--help", "--version"]
    for message in [
      ParsedParityOptions.helpMessage(),
      ParsedWorkflowOptions.helpMessage(),
      ParsedMemoryOptions.helpMessage(),
      ParsedRoutineOptions.helpMessage(),
      ParsedWorkflowManifestOptions.helpMessage(),
      ParsedWorkflowRegisterArguments.helpMessage(),
      ParsedLoopBaselineDiffRoute.helpMessage(),
      ParsedTaskShowOptions.helpMessage(),
      ParsedTaskListOptions.helpMessage(),
      ParsedTaskRunOptions.helpMessage(),
      ParsedTaskDecideOptions.helpMessage()
    ] {
      names.formUnion(longOptionTokens(in: message))
    }
    // Options parsed by hand rather than by swift-argument-parser.
    names.formUnion([
      "--config",            // riela worker --config <worker.json>
      "--check",             // riela loop gates --check
      "--baseline",          // riela loop diff --baseline
      "--follow",            // riela session logs --follow
      "--scope",
      "--output"
    ])
    return names
  }

  static func longOptionTokens(in text: String) -> Set<String> {
    var tokens: Set<String> = []
    var scanner = Substring(text)
    while let range = scanner.range(of: "--") {
      var rest = scanner[range.lowerBound...].dropFirst(2)
      var name = ""
      while let character = rest.first, character.isLetter || character.isNumber || character == "-" {
        name.append(character)
        rest = rest.dropFirst()
      }
      if !name.isEmpty, name.first?.isLetter == true {
        tokens.insert("--\(name)")
      }
      scanner = scanner[range.upperBound...]
    }
    return tokens
  }

  /// Pure bijection check. Tests inject a dummy descriptor to prove the gate
  /// fails when a command is registered without a catalog row.
  public static func violations(
    commands: [CLICommandDescriptor],
    catalog: [SurfaceOperation]
  ) -> [SurfaceParityViolation] {
    var violations = SurfaceCatalog.bijectionViolations(
      surface: .cli,
      actual: Set(commands.map(\.command)),
      declared: Set(catalog.filter { $0.isImplemented(on: .cli) }.compactMap { $0.cli?.command })
    )
    let known = optionNames()
    for operation in catalog {
      for option in operation.cli?.options ?? [] where !known.contains(option) {
        violations.append(.init(
          surface: .cli,
          subject: "\(operation.id) option \(option)",
          reason: "no riela parser declares this option"
        ))
      }
    }
    return violations
  }
}
