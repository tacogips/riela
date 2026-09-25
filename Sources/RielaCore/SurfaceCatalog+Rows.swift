import Foundation

/// Every public control operation, one row each. Adding a CLI command, a
/// GraphQL field, a `/api/v1` route, a library entry point, or a skill command
/// block without a row here fails that surface's gate test.
public extension SurfaceCatalog {
  static let all: [SurfaceOperation] =
    workflowRows
      + sessionRows
      + loopRows
      + registryClientRows
      + consoleRows
      + configurationRows
      + webPlatformRows
      + workRuntimeRows
}

private let workflowDefaults = SurfaceRowDefaults(
  cli: SurfaceExclusion.localProcess("this workflow operation"),
  graphql: SurfaceExclusion.localProcess("this workflow operation"),
  webAPI: SurfaceExclusion.notAConsoleOperation("this workflow operation"),
  library: SurfaceExclusion.notALibraryEntryPoint("this workflow operation"),
  skills: ["riela-workflow-run"]
)

extension SurfaceCatalog {
  static let workflowRows: [SurfaceOperation] = [
    surfaceRow(
      workflowDefaults,
      id: "workflow.validate",
      family: "workflow",
      kind: .process,
      cli: "workflow validate",
      cliOptions: ["--scope", "--workflow-definition-dir", "--output", "--executable", "--node-patch"]
    ),
    surfaceRow(
      workflowDefaults,
      id: "workflow.inspect",
      family: "workflow",
      kind: .query,
      cli: "workflow inspect",
      cliOptions: ["--scope", "--workflow-definition-dir", "--output", "--structure"],
      graphql: graphQLQuery("workflow"),
      library: libraryEntryPoint("inspectWorkflow"),
      skills: ["riela-workflow-run", "riela-workflow-reference"]
    ),
    surfaceRow(
      workflowDefaults,
      id: "workflow.usage",
      family: "workflow",
      kind: .query,
      cli: "workflow usage",
      cliOptions: ["--scope", "--workflow-definition-dir", "--output"],
      graphqlState: .excluded(
        reason: "usage renders the same projection as workflow.inspect; the control plane exposes one field for it",
        design: SurfaceCatalog.controlSurfaceDesign
      )
    ),
    surfaceRow(
      workflowDefaults,
      id: "workflow.run",
      family: "workflow",
      kind: .process,
      cli: "workflow run",
      cliOptions: [
        "--variables", "--variables-file", "--node-patch", "--instance", "--instance-scope",
        "--save-instance", "--mock-scenario", "--output", "--max-steps", "--max-concurrency",
        "--max-loop-iterations", "--disable-default-loop-guard", "--default-timeout-ms",
        "--timeout-ms", "--artifact-root", "--session-store", "--working-dir", "--endpoint",
        "--auth-token", "--auth-token-env", "--from-registry", "--scope"
      ],
      graphql: graphQLMutation("executeWorkflow"),
      library: libraryEntryPoint("executeWorkflow"),
      skills: ["riela-workflow-run", "riela-workflow-reference"]
    ),
    surfaceRow(
      workflowDefaults,
      id: "workflow.execution-summary",
      family: "workflow",
      kind: .query,
      cliState: .excluded(
        reason: "the CLI uses session inspection rather than a separate execution-summary command",
        design: "design-docs/specs/design-native-remote-workflow-execution.md"
      ),
      graphql: graphQLQuery("workflowExecution"),
      webState: .excluded(
        reason: "the summary is read through GraphQL, not a separate web API route",
        design: "design-docs/specs/design-native-remote-workflow-execution.md"
      ),
      libraryState: .excluded(
        reason: "the embedding facade does not expose this remote summary projection",
        design: "design-docs/specs/design-native-remote-workflow-execution.md"
      ),
      skills: ["riela-workflow-run", "riela-workflow-reference"],
      design: "design-docs/specs/design-native-remote-workflow-execution.md"
    ),
    surfaceRow(
      workflowDefaults,
      id: "workflow.list",
      family: "workflow",
      kind: .query,
      cli: "workflow list",
      cliOptions: ["--scope", "--output"],
      graphql: graphQLQuery("workflows"),
      desktop: .implemented
    ),
    surfaceRow(
      workflowDefaults,
      id: "workflow.status",
      family: "workflow",
      kind: .query,
      cli: "workflow status",
      cliOptions: ["--scope", "--output"]
    ),
    surfaceRow(
      workflowDefaults,
      id: "workflow.register",
      family: "workflow",
      kind: .mutation,
      cli: "workflow register",
      cliOptions: ["--mutable", "--overwrite", "--working-dir", "--output"],
      graphql: graphQLMutation("registerMutableWorkflow"),
      desktop: .implemented
    ),
    surfaceRow(
      workflowDefaults,
      id: "workflow.update",
      family: "workflow",
      kind: .mutation,
      cli: "workflow update",
      graphql: graphQLMutation("updateMutableWorkflow"),
      desktop: .implemented
    ),
    surfaceRow(
      workflowDefaults,
      id: "workflow.delete",
      family: "workflow",
      kind: .mutation,
      cli: "workflow delete",
      graphql: graphQLMutation("deleteMutableWorkflow"),
      desktop: .implemented
    ),
    surfaceRow(
      workflowDefaults,
      id: "workflow.activate",
      family: "workflow",
      kind: .mutation,
      cli: "workflow activate",
      graphql: graphQLMutation("activateWorkflow"),
      desktop: .implemented
    ),
    surfaceRow(
      workflowDefaults,
      id: "workflow.deactivate",
      family: "workflow",
      kind: .mutation,
      cli: "workflow deactivate",
      graphql: graphQLMutation("deactivateWorkflow"),
      desktop: .implemented
    ),
    surfaceRow(
      workflowDefaults,
      id: "workflow.consolidate",
      family: "workflow",
      kind: .mutation,
      cli: "workflow consolidate",
      graphql: graphQLMutation("consolidateWorkflows"),
      desktop: .implemented
    ),
    surfaceRow(workflowDefaults, id: "workflow.versions", family: "workflow", kind: .query, cli: "workflow versions"),
    surfaceRow(workflowDefaults, id: "workflow.version", family: "workflow", kind: .query, cli: "workflow version"),
    surfaceRow(workflowDefaults, id: "workflow.restore", family: "workflow", kind: .mutation, cli: "workflow restore"),
    surfaceRow(workflowDefaults, id: "workflow.checkout", family: "workflow", kind: .process, cli: "workflow checkout"),
    surfaceRow(workflowDefaults, id: "workflow.create", family: "workflow", kind: .process, cli: "workflow create"),
    surfaceRow(
      workflowDefaults,
      id: "workflow.self-improve",
      family: "workflow",
      kind: .process,
      cli: "workflow self-improve"
    ),
    surfaceRow(
      workflowDefaults,
      id: "workflow.package",
      family: "workflow",
      kind: .process,
      cli: "workflow package",
      skills: ["riela-package"]
    ),
    surfaceRow(
      workflowDefaults,
      id: "workflow.manifest-validate",
      family: "workflow",
      kind: .process,
      cli: "workflow manifest validate",
      cliOptions: ["--output", "--executable"]
    )
  ]
}

private let sessionDefaults = SurfaceRowDefaults(
  cli: SurfaceExclusion.consoleOnly("this session operation"),
  graphql: SurfaceExclusion.localProcess("this session operation"),
  webAPI: SurfaceExclusion.notAConsoleOperation("this session operation"),
  library: SurfaceExclusion.notALibraryEntryPoint("this session operation"),
  skills: ["riela-workflow-run"]
)

extension SurfaceCatalog {
  static let sessionRows: [SurfaceOperation] = [
    surfaceRow(
      sessionDefaults,
      id: "session.rerun",
      family: "session",
      kind: .mutation,
      cli: "session rerun",
      cliOptions: ["--scope", "--workflow-definition-dir", "--output", "--session-store", "--mock-scenario", "--max-steps"],
      graphql: graphQLMutation("rerunSession"),
      library: libraryEntryPoint("rerunSession"),
      skills: ["riela-workflow-run", "riela-workflow-reference"]
    ),
    surfaceRow(
      sessionDefaults,
      id: "session.resume",
      family: "session",
      kind: .mutation,
      cli: "session resume",
      cliOptions: ["--scope", "--workflow-definition-dir", "--output", "--session-store", "--mock-scenario", "--max-steps"],
      graphql: graphQLMutation("resumeSession"),
      library: libraryEntryPoint("resumeSession"),
      skills: ["riela-workflow-run", "riela-workflow-reference"]
    ),
    surfaceRow(
      sessionDefaults,
      id: "session.stop",
      family: "session",
      kind: .mutation,
      cliState: .excluded(
        reason: "there is no `riela session stop`; cancellation is delivered by signalling the running process",
        design: "\(SurfaceCatalog.controlSurfaceDesign)#5-accepted-deltas"
      ),
      graphql: graphQLMutation("stopSession")
    ),
    surfaceRow(
      sessionDefaults,
      id: "session.continue",
      family: "session",
      kind: .mutation,
      cli: "session continue",
      cliOptions: ["--scope", "--workflow-definition-dir", "--output", "--session-store", "--message-json", "--message-file"],
      graphql: graphQLMutation("continueSession"),
      design: SurfaceCatalog.managerControlPlaneDesign
    ),
    surfaceRow(
      sessionDefaults,
      id: "session.list",
      family: "session",
      kind: .query,
      cli: "session list",
      cliOptions: ["--output", "--session-store", "--status", "--limit"],
      graphql: graphQLQuery("workflowSessions")
    ),
    surfaceRow(
      sessionDefaults,
      id: "session.status",
      family: "session",
      kind: .query,
      cli: "session status",
      cliOptions: ["--output", "--session-store"],
      graphql: graphQLQuery("workflowSession"),
      library: libraryEntryPoint("sessionView"),
      skills: ["riela-workflow-run", "riela-workflow-reference"]
    ),
    surfaceRow(
      sessionDefaults,
      id: "session.progress",
      family: "session",
      kind: .query,
      cli: "session progress",
      cliOptions: ["--output", "--session-store", "--include-children"],
      graphql: graphQLQuery("sessionProgress")
    ),
    surfaceRow(
      sessionDefaults,
      id: "session.health",
      family: "session",
      kind: .query,
      cli: "session health",
      cliOptions: ["--output", "--session-store"],
      graphql: graphQLQuery("sessionHealth")
    ),
    surfaceRow(sessionDefaults, id: "session.latest", family: "session", kind: .query, cli: "session latest"),
    surfaceRow(sessionDefaults, id: "session.step-runs", family: "session", kind: .query, cli: "session step-runs"),
    surfaceRow(sessionDefaults, id: "session.export", family: "session", kind: .process, cli: "session export"),
    surfaceRow(sessionDefaults, id: "session.logs", family: "session", kind: .stream, cli: "session logs"),
    surfaceRow(
      sessionDefaults,
      id: "session.supervision",
      family: "session",
      kind: .query,
      cliState: SurfaceExclusion.supervisionDeleted,
      graphqlState: SurfaceExclusion.supervisionDeleted,
      webState: SurfaceExclusion.supervisionDeleted,
      libraryState: SurfaceExclusion.supervisionDeleted,
      skills: [],
      design: SurfaceCatalog.workRuntimeDesign
    )
  ]
}

private let loopDefaults = SurfaceRowDefaults(
  cli: SurfaceExclusion.localProcess("this loop operation"),
  graphql: SurfaceExclusion.loopNamesRetired,
  webAPI: SurfaceExclusion.notAConsoleOperation("this loop operation"),
  library: SurfaceExclusion.notALibraryEntryPoint("this loop operation"),
  skills: []
)

extension SurfaceCatalog {
  static let loopRows: [SurfaceOperation] = [
    surfaceRow(loopDefaults, id: "loop.status", family: "loop", kind: .query, cli: "loop status"),
    surfaceRow(
      loopDefaults,
      id: "loop.evidence",
      family: "loop",
      kind: .query,
      cli: "loop evidence",
      graphql: graphQLQuery("loopEvidence")
    ),
    surfaceRow(loopDefaults, id: "loop.gates", family: "loop", kind: .query, cli: "loop gates", cliOptions: ["--check"]),
    surfaceRow(loopDefaults, id: "loop.recover", family: "loop", kind: .mutation, cli: "loop recover"),
    surfaceRow(
      loopDefaults,
      id: "loop.list",
      family: "loop",
      kind: .query,
      cli: "loop list",
      cliOptions: ["--status", "--limit", "--output"],
      graphql: graphQLQuery("loopSessions")
    ),
    surfaceRow(loopDefaults, id: "loop.history", family: "loop", kind: .query, cli: "loop history"),
    surfaceRow(
      loopDefaults,
      id: "loop.stats",
      family: "loop",
      kind: .query,
      cli: "loop stats",
      cliOptions: ["--limit"],
      graphql: graphQLQuery("loopWorkflowStats")
    ),
    surfaceRow(
      loopDefaults,
      id: "loop.diff",
      family: "loop",
      kind: .query,
      cli: "loop diff",
      cliOptions: ["--baseline"],
      graphql: graphQLQuery("loopEvidenceDiff")
    ),
    surfaceRow(loopDefaults, id: "loop.findings", family: "loop", kind: .query, cli: "loop findings"),
    surfaceRow(loopDefaults, id: "loop.start", family: "loop", kind: .process, cli: "loop start"),
    surfaceRow(loopDefaults, id: "loop.promote", family: "loop", kind: .mutation, cli: "loop promote"),
    surfaceRow(loopDefaults, id: "loop.baseline", family: "loop", kind: .mutation, cli: "loop baseline"),
    surfaceRow(loopDefaults, id: "loop.regress", family: "loop", kind: .query, cli: "loop regress")
  ]
}
