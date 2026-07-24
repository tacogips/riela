import ArgumentParser

struct RielaClientCommandRouter: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "riela",
    abstract: "Swift-native workflow runtime.",
    version: rielaSwiftMigrationVersion,
    subcommands: [
      WorkflowRoute.self,
      PackageRoute.self,
      NodeRoute.self,
      RrunRoute.self,
      SetupRoute.self,
      MemoryRoute.self,
      NoteRoute.self,
      InstanceRoute.self,
      DoctorRoute.self,
      GarbageCollectionRoute.self,
      SessionRoute.self,
      LoopRoute.self,
      GraphQLRoute.self,
      GQLRoute.self,
      HookRoute.self,
      EventsRoute.self,
      ServeRoute.self,
      CallStepRoute.self,
      WorkflowCallRoute.self,
      VersionRoute.self
    ]
  )
}

protocol RielaClientPassthroughRoute: ParsableCommand {
  var passthroughArguments: [String] { get }
}

struct WorkflowRoute: RielaClientPassthroughRoute {
  static let configuration = passthroughRouteConfiguration("workflow", abstract: "Manage and run workflows.")
  @Argument(parsing: .captureForPassthrough) var passthroughArguments: [String] = []
}

struct PackageRoute: RielaClientPassthroughRoute {
  static let configuration = passthroughRouteConfiguration("package", abstract: "Manage workflow packages.")
  @Argument(parsing: .captureForPassthrough) var passthroughArguments: [String] = []
}

struct NodeRoute: RielaClientPassthroughRoute {
  static let configuration = passthroughRouteConfiguration("node", abstract: "Manage and run node add-ons.")
  @Argument(parsing: .captureForPassthrough) var passthroughArguments: [String] = []
}

struct RrunRoute: RielaClientPassthroughRoute {
  static let configuration = passthroughRouteConfiguration("rrun", abstract: "Run a node add-on.")
  @Argument(parsing: .captureForPassthrough) var passthroughArguments: [String] = []
}

struct SetupRoute: RielaClientPassthroughRoute {
  static let configuration = passthroughRouteConfiguration("setup", abstract: "Set up local runtime dependencies.")
  @Argument(parsing: .captureForPassthrough) var passthroughArguments: [String] = []
}

struct MemoryRoute: RielaClientPassthroughRoute {
  static let configuration = passthroughRouteConfiguration("memory", abstract: "Manage workflow memory.")
  @Argument(parsing: .captureForPassthrough) var passthroughArguments: [String] = []
}

struct NoteRoute: RielaClientPassthroughRoute {
  static let configuration = passthroughRouteConfiguration("note", abstract: "Manage Riela notes.")
  @Argument(parsing: .captureForPassthrough) var passthroughArguments: [String] = []
}

struct InstanceRoute: RielaClientPassthroughRoute {
  static let configuration = passthroughRouteConfiguration("instance", abstract: "Manage workflow instances.")
  @Argument(parsing: .captureForPassthrough) var passthroughArguments: [String] = []
}

struct DoctorRoute: RielaClientPassthroughRoute {
  static let configuration = passthroughRouteConfiguration("doctor", abstract: "Inspect local runtime readiness.")
  @Argument(parsing: .captureForPassthrough) var passthroughArguments: [String] = []
}

struct GarbageCollectionRoute: RielaClientPassthroughRoute {
  static let configuration = passthroughRouteConfiguration("gc", abstract: "Remove expired runtime data.")
  @Argument(parsing: .captureForPassthrough) var passthroughArguments: [String] = []
}

struct SessionRoute: RielaClientPassthroughRoute {
  static let configuration = passthroughRouteConfiguration("session", abstract: "Inspect and continue sessions.")
  @Argument(parsing: .captureForPassthrough) var passthroughArguments: [String] = []
}

struct LoopRoute: RielaClientPassthroughRoute {
  static let configuration = passthroughRouteConfiguration("loop", abstract: "Inspect and control workflow loops.")
  @Argument(parsing: .captureForPassthrough) var passthroughArguments: [String] = []
}

struct GraphQLRoute: RielaClientPassthroughRoute {
  static let configuration = passthroughRouteConfiguration("graphql", abstract: "Execute GraphQL control-plane operations.")
  @Argument(parsing: .captureForPassthrough) var passthroughArguments: [String] = []
}

struct GQLRoute: RielaClientPassthroughRoute {
  static let configuration = passthroughRouteConfiguration("gql", abstract: "Alias for graphql.", shouldDisplay: false)
  @Argument(parsing: .captureForPassthrough) var passthroughArguments: [String] = []
}

struct HookRoute: RielaClientPassthroughRoute {
  static let configuration = passthroughRouteConfiguration("hook", abstract: "Execute workflow hooks.")
  @Argument(parsing: .captureForPassthrough) var passthroughArguments: [String] = []
}

struct EventsRoute: RielaClientPassthroughRoute {
  static let configuration = passthroughRouteConfiguration("events", abstract: "Manage external event sources.")
  @Argument(parsing: .captureForPassthrough) var passthroughArguments: [String] = []
}

struct ServeRoute: RielaClientPassthroughRoute {
  static let configuration = passthroughRouteConfiguration("serve", abstract: "Serve Riela APIs and workflows.")
  @Argument(parsing: .captureForPassthrough) var passthroughArguments: [String] = []
}

struct CallStepRoute: RielaClientPassthroughRoute {
  static let configuration = passthroughRouteConfiguration("call-step", abstract: "Call a workflow step.")
  @Argument(parsing: .captureForPassthrough) var passthroughArguments: [String] = []
}

struct WorkflowCallRoute: RielaClientPassthroughRoute {
  static let configuration = passthroughRouteConfiguration("workflow-call", abstract: "Call a step in another workflow.")
  @Argument(parsing: .captureForPassthrough) var passthroughArguments: [String] = []
}

struct VersionRoute: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "version",
    abstract: "Print the Riela version.",
    shouldDisplay: false,
    helpNames: []
  )
}

private func passthroughRouteConfiguration(
  _ commandName: String,
  abstract: String,
  shouldDisplay: Bool = true
) -> CommandConfiguration {
  CommandConfiguration(
    commandName: commandName,
    abstract: abstract,
    shouldDisplay: shouldDisplay,
    helpNames: []
  )
}
