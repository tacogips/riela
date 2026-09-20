import Foundation

private let consoleDefaults = SurfaceRowDefaults(
  cli: SurfaceExclusion.consoleOnly("this console read"),
  graphql: SurfaceExclusion.consoleOnly("this console read"),
  webAPI: .excluded(
    reason: "retired: the console reads this through GraphQL, and the parallel /api/v1 route was deleted",
    design: "\(SurfaceCatalog.controlSurfaceDesign)#24-retire-the-parallel-console-surface"
  ),
  library: SurfaceExclusion.notALibraryEntryPoint("a console read"),
  skills: []
)

private let webPlatformDefaults = SurfaceRowDefaults(
  cli: SurfaceExclusion.consoleOnly("this web route"),
  graphql: SurfaceExclusion.byteTransfer("this web route"),
  webAPI: SurfaceExclusion.notAConsoleOperation("this web route"),
  library: SurfaceExclusion.notALibraryEntryPoint("a web route"),
  skills: []
)

private let configurationDefaults = SurfaceRowDefaults(
  cli: SurfaceExclusion.consoleOnly("this configuration operation"),
  graphql: SurfaceExclusion.consoleOnly("this configuration operation"),
  webAPI: .excluded(
    reason: "configuration already lives on GraphQL; no parallel JSON route is added",
    design: "\(SurfaceCatalog.controlSurfaceDesign)#24-retire-the-parallel-console-surface"
  ),
  library: SurfaceExclusion.notALibraryEntryPoint("configuration"),
  skills: []
)

/// Evidence for the console run reads that stay on `/api/v1` for now. They are
/// bounded byte projections with their own truncation policy, so moving them is
/// its own piece of work rather than a silent "GraphQL later".
private let consoleRunReadEvidence =
  "bounded run projections keep WorkflowWebProjectionPolicy truncation; moving them needs its own plan "
    + "(design-control-surface-parity 2.4 covers instance list, detail and overview only)"

extension SurfaceCatalog {
  static let consoleRows: [SurfaceOperation] = [
    surfaceRow(
      consoleDefaults,
      id: "console.instances",
      family: "console",
      kind: .query,
      graphql: graphQLQuery("consoleInstances"),
      desktop: .implemented
    ),
    surfaceRow(
      consoleDefaults,
      id: "console.instance",
      family: "console",
      kind: .query,
      graphql: graphQLQuery("consoleInstance"),
      desktop: .implemented
    ),
    surfaceRow(
      consoleDefaults,
      id: "console.ops-overview",
      family: "console",
      kind: .query,
      graphql: graphQLQuery("opsOverview"),
      desktop: .implemented
    ),
    surfaceRow(
      consoleDefaults,
      id: "console.bootstrap",
      family: "console",
      kind: .query,
      graphqlState: SurfaceExclusion.authHandshake("the bootstrap handshake"),
      web: webRoute("GET", "/api/v1/bootstrap"),
      desktop: .implemented
    ),
    surfaceRow(
      consoleDefaults,
      id: "console.workflow-sources",
      family: "console",
      kind: .query,
      graphqlState: .blocked(evidence: consoleRunReadEvidence),
      web: webRoute("GET", "/api/v1/workflows/sources"),
      desktop: .implemented
    ),
    surfaceRow(
      consoleDefaults,
      id: "console.workflow-definition",
      family: "console",
      kind: .query,
      graphqlState: SurfaceExclusion.byteTransfer("the bounded workflow-definition projection"),
      web: webRoute("GET", "/api/v1/workflows/sources/{sourceId}/definition"),
      desktop: .implemented
    ),
    surfaceRow(
      consoleDefaults,
      id: "console.instance-executions",
      family: "console",
      kind: .query,
      graphqlState: .blocked(evidence: consoleRunReadEvidence),
      web: webRoute("GET", "/api/v1/instances/{identity}/executions"),
      desktop: .implemented
    ),
    surfaceRow(
      consoleDefaults,
      id: "console.instance-execution-detail",
      family: "console",
      kind: .query,
      graphqlState: .blocked(evidence: consoleRunReadEvidence),
      web: webRoute("GET", "/api/v1/instances/{identity}/executions/{sessionId}"),
      desktop: .implemented
    ),
    surfaceRow(
      consoleDefaults,
      id: "console.execution-detail",
      family: "console",
      kind: .query,
      graphqlState: .blocked(evidence: consoleRunReadEvidence),
      web: webRoute("GET", "/api/v1/executions/{sessionId}"),
      desktop: .implemented
    ),
    surfaceRow(
      consoleDefaults,
      id: "console.instance-create",
      family: "console",
      kind: .mutation,
      graphqlState: .blocked(
        evidence: "console instance creation writes daemon preferences, not the WorkflowInstanceDefinition store "
          + "Mutation.createWorkflowInstance owns; unifying the two stores needs its own plan"
      ),
      web: webRoute("POST", "/api/v1/instances"),
      desktop: .implemented
    ),
    surfaceRow(
      consoleDefaults,
      id: "console.instance-action",
      family: "console",
      kind: .mutation,
      graphqlState: .blocked(
        evidence: "start/stop/restart drive the in-process daemon runtime; exposing it needs the runtime lifecycle "
          + "contract the Work Runtime design defines"
      ),
      web: webRoute("POST", "/api/v1/instances/{identity}/actions"),
      desktop: .implemented
    )
  ]

  static let configurationRows: [SurfaceOperation] = [
    surfaceRow(
      configurationDefaults,
      id: "configuration.read",
      family: "configuration",
      kind: .query,
      graphql: graphQLQuery("configuration"),
      desktop: .implemented
    ),
    surfaceRow(
      configurationDefaults,
      id: "configuration.update-assistant",
      family: "configuration",
      kind: .mutation,
      graphql: graphQLMutation("updateAssistantConfiguration"),
      desktop: .implemented
    ),
    surfaceRow(
      configurationDefaults,
      id: "configuration.update-appearance",
      family: "configuration",
      kind: .mutation,
      graphql: graphQLMutation("updateAppearanceConfiguration"),
      desktop: .implemented
    ),
    surfaceRow(
      configurationDefaults,
      id: "configuration.update-http-server",
      family: "configuration",
      kind: .mutation,
      graphql: graphQLMutation("updateHTTPServerConfiguration"),
      desktop: .implemented
    ),
    surfaceRow(
      configurationDefaults,
      id: "configuration.create-profile",
      family: "configuration",
      kind: .mutation,
      graphql: graphQLMutation("createProfileConfiguration"),
      desktop: .implemented
    ),
    surfaceRow(
      configurationDefaults,
      id: "configuration.remove-profile",
      family: "configuration",
      kind: .mutation,
      graphql: graphQLMutation("removeProfileConfiguration"),
      desktop: .implemented
    ),
    surfaceRow(
      configurationDefaults,
      id: "configuration.switch-profile",
      family: "configuration",
      kind: .mutation,
      graphql: graphQLMutation("switchProfileConfiguration"),
      desktop: .implemented
    ),
    surfaceRow(
      configurationDefaults,
      id: "configuration.add-workflow-directory",
      family: "configuration",
      kind: .mutation,
      graphql: graphQLMutation("addWorkflowDirectoryConfiguration"),
      desktop: .implemented
    ),
    surfaceRow(
      configurationDefaults,
      id: "configuration.update-workflow-instance",
      family: "configuration",
      kind: .mutation,
      graphql: graphQLMutation("updateWorkflowInstanceConfiguration"),
      desktop: .implemented
    ),
    surfaceRow(
      configurationDefaults,
      id: "configuration.register-event-source",
      family: "configuration",
      kind: .mutation,
      graphql: graphQLMutation("registerEventSourceConfiguration"),
      desktop: .implemented
    )
  ]

  static let webPlatformRows: [SurfaceOperation] = authRows + editorRows + workerSettingsRows

  private static var authRows: [SurfaceOperation] {
    [
      ("status", SurfaceOperation.Kind.query, "GET", "/api/v1/auth/status"),
      ("register-options", .mutation, "POST", "/api/v1/auth/register/options"),
      ("register-finish", .mutation, "POST", "/api/v1/auth/register/finish"),
      ("login-options", .mutation, "POST", "/api/v1/auth/login/options"),
      ("login-finish", .mutation, "POST", "/api/v1/auth/login/finish"),
      ("device-start", .mutation, "POST", "/api/v1/auth/device/start"),
      ("device-info", .query, "POST", "/api/v1/auth/device/info"),
      ("device-poll", .query, "POST", "/api/v1/auth/device/poll"),
      ("device-cancel", .mutation, "POST", "/api/v1/auth/device/cancel"),
      ("logout", .mutation, "POST", "/api/v1/auth/logout")
    ].map { name, kind, method, path in
      surfaceRow(
        webPlatformDefaults,
        id: "web-auth.\(name)",
        family: "web-auth",
        kind: kind,
        graphqlState: SurfaceExclusion.authHandshake("the Passkey handshake"),
        web: webRoute(method, path),
        desktop: .implemented
      )
    }
  }

  private static var editorRows: [SurfaceOperation] {
    [
      ("node-settings", SurfaceOperation.Kind.query, "POST", "/api/v1/workflow-editor/node-settings"),
      ("definition", .query, "POST", "/api/v1/workflow-editor/definition"),
      ("launch-start", .mutation, "POST", "/api/v1/workflow-editor/launches"),
      ("launch-status", .query, "GET", "/api/v1/workflow-editor/launches/{launchId}"),
      ("generation-start", .mutation, "POST", "/api/v1/workflow-editor/generations"),
      ("generation-status", .query, "GET", "/api/v1/workflow-editor/generations/{generationId}"),
      ("generation-cancel", .mutation, "DELETE", "/api/v1/workflow-editor/generations/{generationId}"),
      ("run-evidence", .query, "GET", "/api/v1/workflow-editor/runs/{sessionId}"),
      ("run-step-evidence", .query, "GET", "/api/v1/workflow-editor/runs/{sessionId}/steps/{executionId}"),
      ("editable-copy", .mutation, "POST", "/api/v1/workflows/sources/{sourceId}/editable-copy")
    ].map { name, kind, method, path in
      surfaceRow(
        webPlatformDefaults,
        id: "web-editor.\(name)",
        family: "web-editor",
        kind: kind,
        graphqlState: .excluded(
          reason: "the workflow editor performs file operations on a working copy, not control-plane operations",
          design: "\(SurfaceCatalog.controlSurfaceDesign)#24-retire-the-parallel-console-surface"
        ),
        web: webRoute(method, path),
        desktop: .implemented
      )
    }
  }

  private static var workerSettingsRows: [SurfaceOperation] {
    [
      surfaceRow(
        webPlatformDefaults,
        id: "web-settings.workers-read",
        family: "web-settings",
        kind: .query,
        graphqlState: SurfaceExclusion.localProcess("distributed controller settings"),
        web: webRoute("GET", "/api/v1/settings/workers"),
        desktop: .implemented
      ),
      surfaceRow(
        webPlatformDefaults,
        id: "web-settings.workers-write",
        family: "web-settings",
        kind: .mutation,
        graphqlState: SurfaceExclusion.localProcess("distributed controller settings"),
        web: webRoute("PUT", "/api/v1/settings/workers"),
        desktop: .implemented
      ),
      surfaceRow(
        webPlatformDefaults,
        id: "web-settings.worker-credentials",
        family: "web-settings",
        kind: .mutation,
        graphqlState: .excluded(
          reason: "worker credentials are opened in a local editor by the desktop host; they never cross the control plane",
          design: "\(SurfaceCatalog.controlSurfaceDesign)#24-retire-the-parallel-console-surface"
        ),
        web: webRoute("POST", "/api/v1/settings/worker-credentials"),
        desktop: .implemented
      )
    ]
  }

  /// Work Runtime operations enter the catalog before their commands exist
  /// (design delta D6). They are `blocked` on the P0 plan, not excluded.
  static let workRuntimeRows: [SurfaceOperation] = {
    let evidence = "not implemented here; \(SurfaceCatalog.workRuntimeP0Plan) ships the model and store first"
    let defaults = SurfaceRowDefaults(
      cli: .blocked(evidence: evidence),
      graphql: .blocked(evidence: evidence),
      webAPI: SurfaceExclusion.notAConsoleOperation("a Work Runtime operation"),
      library: .blocked(evidence: evidence),
      design: SurfaceCatalog.workRuntimeDesign
    )
    return [
      surfaceRow(defaults, id: "task.submit", family: "task", kind: .mutation),
      surfaceRow(defaults, id: "task.list", family: "task", kind: .query),
      surfaceRow(defaults, id: "task.show", family: "task", kind: .query),
      surfaceRow(defaults, id: "task.serve", family: "task", kind: .stream),
      surfaceRow(defaults, id: "intent.create", family: "intent", kind: .mutation),
      surfaceRow(defaults, id: "intent.list", family: "intent", kind: .query),
      surfaceRow(defaults, id: "intent.show", family: "intent", kind: .query)
    ]
  }()
}
