import Foundation

private let packageDefaults = SurfaceRowDefaults(
  cli: SurfaceExclusion.localProcess("this package operation"),
  graphql: SurfaceExclusion.localProcess("package management"),
  webAPI: SurfaceExclusion.notAConsoleOperation("package management"),
  library: SurfaceExclusion.notALibraryEntryPoint("package management"),
  skills: ["riela-package"]
)

private let nodeDefaults = SurfaceRowDefaults(
  cli: SurfaceExclusion.localProcess("this node operation"),
  graphql: SurfaceExclusion.localProcess("node add-on management"),
  webAPI: SurfaceExclusion.notAConsoleOperation("node add-on management"),
  library: SurfaceExclusion.notALibraryEntryPoint("node add-on management"),
  skills: ["riela-node-addons"]
)

private let memoryDefaults = SurfaceRowDefaults(
  cli: SurfaceExclusion.localProcess("this memory operation"),
  graphql: SurfaceExclusion.memoryStaysLocal,
  webAPI: SurfaceExclusion.notAConsoleOperation("workflow memory"),
  library: SurfaceExclusion.notALibraryEntryPoint("workflow memory"),
  skills: []
)

private let instanceDefaults = SurfaceRowDefaults(
  cli: SurfaceExclusion.consoleOnly("this instance operation"),
  graphql: SurfaceExclusion.localProcess("this instance operation"),
  webAPI: SurfaceExclusion.notAConsoleOperation("this instance operation"),
  library: SurfaceExclusion.notALibraryEntryPoint("instance management"),
  skills: []
)

private let specialistDefaults = SurfaceRowDefaults(
  cli: SurfaceExclusion.localProcess("this specialist operation"),
  graphql: SurfaceExclusion.specialistFoldsIntoTask,
  webAPI: SurfaceExclusion.notAConsoleOperation("specialist operation"),
  library: SurfaceExclusion.notALibraryEntryPoint("specialist operation"),
  skills: []
)

private let localToolDefaults = SurfaceRowDefaults(
  cli: SurfaceExclusion.localProcess("this operation"),
  graphql: SurfaceExclusion.localProcess("this local runtime operation"),
  webAPI: SurfaceExclusion.notAConsoleOperation("this local runtime operation"),
  library: SurfaceExclusion.notALibraryEntryPoint("this local runtime operation"),
  skills: []
)

private let routineDefaults = SurfaceRowDefaults(
  cli: SurfaceExclusion.consoleOnly("this routine operation"),
  graphql: SurfaceExclusion.localProcess("this routine operation"),
  webAPI: SurfaceExclusion.notAConsoleOperation("this routine operation"),
  library: SurfaceExclusion.notALibraryEntryPoint("routine management"),
  skills: []
)

private let graphQLClientDefaults = SurfaceRowDefaults(
  cli: SurfaceExclusion.localProcess("this GraphQL client command"),
  graphql: .excluded(
    reason: "this is the CLI client for a control-plane field; the field itself is cataloged by its own operation row",
    design: "\(SurfaceCatalog.controlSurfaceDesign)#23-derive-the-graphql-surface"
  ),
  webAPI: SurfaceExclusion.notAConsoleOperation("the GraphQL client command"),
  library: SurfaceExclusion.notALibraryEntryPoint("the GraphQL client command"),
  skills: ["riela-workflow-reference"]
)

extension SurfaceCatalog {
  static let registryClientRows: [SurfaceOperation] =
    packageRows + nodeRows + memoryRows + instanceRows + specialistRows
      + localToolRows + eventRows + routineCLIRows + serveRows + graphQLClientRows + operatorRows
      + taskMutationRows

  private static var taskMutationRows: [SurfaceOperation] {
    let p5Evidence = "the GraphQL task API and task board land in work-runtime P5"
    let defaults = SurfaceRowDefaults(
      cli: SurfaceExclusion.localProcess("this task operation"),
      graphql: .blocked(evidence: p5Evidence),
      webAPI: SurfaceExclusion.notAConsoleOperation("a Work Runtime operation"),
      library: .blocked(evidence: p5Evidence),
      design: SurfaceCatalog.workRuntimeDesign
    )
    let sharedOptions = ["--scope", "--session-store", "--working-dir", "--output"]
    return [
      surfaceRow(
        defaults,
        id: "task.run",
        family: "task",
        kind: .process,
        cli: "task run",
        cliOptions: sharedOptions + ["--dry-run"]
      ),
      surfaceRow(
        defaults,
        id: "task.decide",
        family: "task",
        kind: .mutation,
        cli: "task decide",
        cliOptions: sharedOptions + [
          "--accept", "--reject", "--rerun", "--cancel", "--principal", "--expected-version", "--decision-id"
        ]
      )
    ]
  }

  private static var packageRows: [SurfaceOperation] {
    [
      ("search", SurfaceOperation.Kind.query), ("list", .query), ("status", .query),
      ("install", .process), ("ci", .process), ("update", .process), ("remove", .process),
      ("checkout", .process), ("run", .process), ("temp-run", .process), ("init", .process),
      ("validate", .process), ("pack", .process), ("publish", .process), ("registry", .process)
    ].map { name, kind in
      surfaceRow(packageDefaults, id: "package.\(name)", family: "package", kind: kind, cli: "package \(name)")
    }
  }

  private static var nodeRows: [SurfaceOperation] {
    [("search", SurfaceOperation.Kind.query), ("list", .query), ("install", .process), ("run", .process)]
      .map { name, kind in
        surfaceRow(nodeDefaults, id: "node.\(name)", family: "node", kind: kind, cli: "node \(name)")
      }
      + [
        surfaceRow(
          nodeDefaults,
          id: "node.run-alias",
          family: "node",
          kind: .process,
          cli: "rrun",
          design: SurfaceCatalog.controlSurfaceDesign
        )
      ]
  }

  private static var memoryRows: [SurfaceOperation] {
    [
      ("save", SurfaceOperation.Kind.mutation), ("update", .mutation), ("load", .query),
      ("search", .query), ("metadata", .query), ("tags", .query), ("related-ids", .query)
    ].map { name, kind in
      surfaceRow(
        memoryDefaults,
        id: "memory.\(name)",
        family: "memory",
        kind: kind,
        cli: "memory \(name)",
        cliOptions: ["--workflow-id", "--payload-json", "--payload-file", "--record-id", "--all-workflows"]
      )
    }
  }

  private static var instanceRows: [SurfaceOperation] {
    [
      surfaceRow(
        instanceDefaults,
        id: "instance.list",
        family: "instance",
        kind: .query,
        cli: "instance list",
        graphql: graphQLQuery("workflowInstances"),
        desktop: .implemented
      ),
      surfaceRow(
        instanceDefaults,
        id: "instance.show",
        family: "instance",
        kind: .query,
        cli: "instance show",
        graphql: graphQLQuery("workflowInstance"),
        desktop: .implemented
      ),
      surfaceRow(
        instanceDefaults,
        id: "instance.create",
        family: "instance",
        kind: .mutation,
        cli: "instance create",
        graphql: graphQLMutation("createWorkflowInstance")
      ),
      surfaceRow(
        instanceDefaults,
        id: "instance.update",
        family: "instance",
        kind: .mutation,
        cli: "instance update",
        graphql: graphQLMutation("updateWorkflowInstance")
      ),
      surfaceRow(
        instanceDefaults,
        id: "instance.remove",
        family: "instance",
        kind: .mutation,
        cli: "instance remove",
        graphql: graphQLMutation("deleteWorkflowInstance")
      )
    ]
  }

  private static var specialistRows: [SurfaceOperation] {
    [
      ("catalog", SurfaceOperation.Kind.query), ("catalog-refresh", .mutation), ("serve", .process),
      ("submit", .mutation), ("status", .query), ("cancel", .mutation), ("execute", .process),
      ("reconcile", .process), ("smoke", .process)
    ].map { name, kind in
      surfaceRow(specialistDefaults, id: "specialist.\(name)", family: "specialist", kind: kind, cli: "specialist \(name)")
    }
  }

  private static var localToolRows: [SurfaceOperation] {
    [
      surfaceRow(localToolDefaults, id: "setup.container", family: "setup", kind: .process, cli: "setup container"),
      surfaceRow(localToolDefaults, id: "doctor.report", family: "doctor", kind: .query, cli: "doctor"),
      surfaceRow(localToolDefaults, id: "gc.sweep", family: "gc", kind: .process, cli: "gc"),
      surfaceRow(localToolDefaults, id: "version.print", family: "version", kind: .query, cli: "version"),
      surfaceRow(
        localToolDefaults,
        id: "step.call",
        family: "step",
        kind: .process,
        cli: "call-step",
        skills: ["riela-workflow-reference"]
      ),
      surfaceRow(
        localToolDefaults,
        id: "step.call-cross-workflow",
        family: "step",
        kind: .process,
        cli: "workflow-call",
        skills: ["riela-workflow-reference"]
      ),
      surfaceRow(localToolDefaults, id: "hook.codex", family: "hook", kind: .process, cli: "hook codex"),
      surfaceRow(localToolDefaults, id: "hook.claude", family: "hook", kind: .process, cli: "hook claude"),
      surfaceRow(localToolDefaults, id: "hook.cursor", family: "hook", kind: .process, cli: "hook cursor"),
      surfaceRow(
        localToolDefaults,
        id: "kaiba.instance-list",
        family: "kaiba",
        kind: .query,
        cli: "kaiba instance list"
      ),
      surfaceRow(localToolDefaults, id: "kaiba.instance-show", family: "kaiba", kind: .query, cli: "kaiba instance show"),
      surfaceRow(
        localToolDefaults,
        id: "kaiba.instance-add",
        family: "kaiba",
        kind: .mutation,
        cli: "kaiba instance add"
      ),
      surfaceRow(
        localToolDefaults,
        id: "kaiba.instance-update",
        family: "kaiba",
        kind: .mutation,
        cli: "kaiba instance update"
      ),
      surfaceRow(
        localToolDefaults,
        id: "kaiba.instance-remove",
        family: "kaiba",
        kind: .mutation,
        cli: "kaiba instance remove"
      ),
      surfaceRow(localToolDefaults, id: "kaiba.instance-test", family: "kaiba", kind: .process, cli: "kaiba instance test"),
      surfaceRow(
        localToolDefaults,
        id: "kaiba.instance-set-default",
        family: "kaiba",
        kind: .mutation,
        cli: "kaiba instance set-default"
      )
    ]
  }

  private static var eventRows: [SurfaceOperation] {
    let defaults = SurfaceRowDefaults(
      cli: SurfaceExclusion.localProcess("this event-source operation"),
      graphql: SurfaceExclusion.localProcess("event-source operation"),
      webAPI: SurfaceExclusion.notAConsoleOperation("event-source operation"),
      library: SurfaceExclusion.notALibraryEntryPoint("event-source operation"),
      skills: ["riela-event-sources"]
    )
    return [
      ("validate", SurfaceOperation.Kind.process, "events validate"),
      ("emit", .mutation, "events emit"),
      ("list", .query, "events list"),
      ("replay", .mutation, "events replay"),
      ("serve", .stream, "events serve"),
      ("replies", .query, "events replies"),
      ("schedules-list", .query, "events schedules list"),
      ("schedules-inspect", .query, "events schedules inspect"),
      ("schedules-cancel", .mutation, "events schedules cancel")
    ].map { name, kind, command in
      surfaceRow(defaults, id: "events.\(name)", family: "events", kind: kind, cli: command)
    }
  }

  private static var routineCLIRows: [SurfaceOperation] {
    [
      surfaceRow(
        routineDefaults,
        id: "routine.create",
        family: "routine",
        kind: .mutation,
        cli: "routine create",
        graphql: graphQLMutation("createRoutine"),
        desktop: .implemented
      ),
      surfaceRow(
        routineDefaults,
        id: "routine.list",
        family: "routine",
        kind: .query,
        cli: "routine list",
        graphql: graphQLQuery("routines"),
        desktop: .implemented
      ),
      surfaceRow(
        routineDefaults,
        id: "routine.inspect",
        family: "routine",
        kind: .query,
        cli: "routine inspect",
        graphql: graphQLQuery("routine"),
        desktop: .implemented
      ),
      surfaceRow(
        routineDefaults,
        id: "routine.complete",
        family: "routine",
        kind: .mutation,
        cli: "routine complete",
        graphql: graphQLMutation("completeRoutine")
      ),
      surfaceRow(
        routineDefaults,
        id: "routine.set-status",
        family: "routine",
        kind: .mutation,
        cli: "routine enable",
        graphql: graphQLMutation("setRoutineStatus")
      ),
      surfaceRow(
        routineDefaults,
        id: "routine.disable",
        family: "routine",
        kind: .mutation,
        cli: "routine disable",
        graphqlState: .excluded(
          reason: "disable is the negative form of routine.set-status and shares Mutation.setRoutineStatus",
          design: SurfaceCatalog.controlSurfaceDesign
        )
      ),
      surfaceRow(
        routineDefaults,
        id: "routine.delete",
        family: "routine",
        kind: .mutation,
        cli: "routine delete",
        graphql: graphQLMutation("deleteRoutine")
      )
    ]
  }

  private static var serveRows: [SurfaceOperation] {
    let defaults = SurfaceRowDefaults(
      cli: SurfaceExclusion.localProcess("this serve operation"),
      graphql: SurfaceExclusion.localProcess("serving the API"),
      webAPI: SurfaceExclusion.notAConsoleOperation("serving the API"),
      library: SurfaceExclusion.notALibraryEntryPoint("serving the API"),
      skills: ["riela-workflow-run"]
    )
    return [
      surfaceRow(defaults, id: "serve.host", family: "serve", kind: .stream, cli: "serve",
                 cliOptions: ["--host", "--port", "--web-root", "--session-store", "--working-dir"]),
      surfaceRow(defaults, id: "serve.status", family: "serve", kind: .query, cli: "serve status"),
      surfaceRow(defaults, id: "serve.health", family: "serve", kind: .query, cli: "serve health"),
      surfaceRow(defaults, id: "serve.overview", family: "serve", kind: .query, cli: "serve overview"),
      surfaceRow(defaults, id: "serve.graphql", family: "serve", kind: .process, cli: "serve graphql")
    ]
  }

  private static var graphQLClientRows: [SurfaceOperation] {
    [
      surfaceRow(graphQLClientDefaults, id: "graphql.schema", family: "graphql", kind: .query, cli: "graphql schema"),
      surfaceRow(
        graphQLClientDefaults,
        id: "graphql.execute",
        family: "graphql",
        kind: .process,
        cli: "graphql execute",
        cliOptions: ["--query", "--query-file", "--document", "--document-file", "--operation-name", "--variables"]
      ),
      surfaceRow(
        graphQLClientDefaults,
        id: "graphql.document",
        family: "graphql",
        kind: .process,
        cli: "graphql document",
        cliOptions: ["--query", "--query-file", "--document", "--document-file", "--operation-name", "--variables"],
        library: libraryEntryPoint("executeGraphQLDocument")
      ),
      surfaceRow(
        graphQLClientDefaults,
        id: "graphql.note-document",
        family: "graphql",
        kind: .process,
        cli: "graphql note-document",
        graphqlState: .excluded(
          reason: "the note GraphQL domain moved to the kaiba package; riela keeps only the client command",
          design: SurfaceCatalog.controlSurfaceDesign
        )
      ),
      surfaceRow(graphQLClientDefaults, id: "graphql.session", family: "graphql", kind: .query, cli: "graphql session"),
      surfaceRow(
        graphQLClientDefaults,
        id: "graphql.inspect-session",
        family: "graphql",
        kind: .query,
        cli: "graphql inspect-session"
      ),
      surfaceRow(
        graphQLClientDefaults,
        id: "graphql.workflow-session",
        family: "graphql",
        kind: .query,
        cli: "graphql workflow-session"
      ),
      surfaceRow(
        graphQLClientDefaults,
        id: "graphql.session-progress",
        family: "graphql",
        kind: .query,
        cli: "graphql session-progress",
        cliOptions: ["--include-children"]
      ),
      surfaceRow(
        graphQLClientDefaults,
        id: "graphql.session-health",
        family: "graphql",
        kind: .query,
        cli: "graphql session-health"
      ),
      surfaceRow(
        graphQLClientDefaults,
        id: "graphql.manager-session",
        family: "graphql",
        kind: .query,
        cli: "graphql manager-session",
        graphql: graphQLQuery("managerSession"),
        design: SurfaceCatalog.managerControlPlaneDesign
      ),
      surfaceRow(
        graphQLClientDefaults,
        id: "graphql.send-manager-message",
        family: "graphql",
        kind: .mutation,
        cli: "graphql send-manager-message",
        graphql: graphQLMutation("sendManagerMessage"),
        skills: ["riela-manager-control"],
        design: SurfaceCatalog.managerControlPlaneDesign
      ),
      surfaceRow(
        graphQLClientDefaults,
        id: "graphql.replay-communication",
        family: "graphql",
        kind: .mutation,
        cli: "graphql replay-communication",
        graphql: graphQLMutation("replayCommunication"),
        skills: ["riela-manager-control"],
        design: SurfaceCatalog.managerControlPlaneDesign
      ),
      surfaceRow(
        graphQLClientDefaults,
        id: "graphql.retry-communication-delivery",
        family: "graphql",
        kind: .mutation,
        cli: "graphql retry-communication-delivery",
        graphql: graphQLMutation("retryCommunicationDelivery"),
        skills: ["riela-manager-control"],
        design: SurfaceCatalog.managerControlPlaneDesign
      ),
      surfaceRow(
        graphQLClientDefaults,
        id: "graphql.retry-communication",
        family: "graphql",
        kind: .mutation,
        cli: "graphql retry-communication",
        graphqlState: .excluded(
          reason: "short alias of graphql.retry-communication-delivery; it shares Mutation.retryCommunicationDelivery",
          design: SurfaceCatalog.managerControlPlaneDesign
        )
      ),
      surfaceRow(
        graphQLClientDefaults,
        id: "graphql.alias",
        family: "graphql",
        kind: .process,
        cli: "gql",
        graphqlState: .excluded(
          reason: "hidden alias of the graphql command family; it adds no control-plane field",
          design: SurfaceCatalog.controlSurfaceDesign
        )
      )
    ]
  }

  private static var operatorRows: [SurfaceOperation] {
    let defaults = SurfaceRowDefaults(
      cli: SurfaceExclusion.localProcess("this operator command"),
      graphql: SurfaceExclusion.localProcess("credential and worker administration"),
      webAPI: SurfaceExclusion.notAConsoleOperation("credential administration"),
      library: SurfaceExclusion.notALibraryEntryPoint("operator administration"),
      skills: []
    )
    return [
      surfaceRow(defaults, id: "auth.invite", family: "auth", kind: .mutation, cli: "auth invite"),
      surfaceRow(defaults, id: "auth.users", family: "auth", kind: .query, cli: "auth users"),
      surfaceRow(defaults, id: "auth.revoke-user", family: "auth", kind: .mutation, cli: "auth revoke-user"),
      surfaceRow(defaults, id: "auth.revoke-key", family: "auth", kind: .mutation, cli: "auth revoke-key"),
      surfaceRow(defaults, id: "worker.run", family: "worker", kind: .stream, cli: "worker", cliOptions: ["--config"]),
      surfaceRow(defaults, id: "worker.status", family: "worker", kind: .query, cli: "worker status", cliOptions: ["--config"])
    ]
  }
}
