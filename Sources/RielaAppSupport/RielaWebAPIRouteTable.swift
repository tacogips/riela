import Foundation

/// The declared `/api/v1` route table (design delta D7).
///
/// `/api/v1` routing is switch- and prefix-based, so each routing owner
/// declares its routes here and the web gate asserts a bijection between this
/// table and the `SurfaceCatalog` rows that claim the web API. The gate also
/// checks that every declared route's path literal appears in its owner file
/// and that no owner serves a path the table omits.
public struct RielaWebAPIRoute: Sendable, Equatable {
  public var method: String
  /// Parameter segments use `{name}`, matching `SurfaceWebAPIBinding`.
  public var path: String
  /// Repository-relative source file that dispatches this route.
  public var owner: String

  public init(method: String, path: String, owner: String) {
    self.method = method
    self.path = path
    self.owner = owner
    self.ownerMarker = nil
  }

  /// Some routes are dispatched from split path components rather than from a
  /// literal, so the owner declares the token the gate should look for.
  public var ownerMarker: String?

  public init(method: String, path: String, owner: String, ownerMarker: String) {
    self.init(method: method, path: path, owner: owner)
    self.ownerMarker = ownerMarker
  }

  public var route: String { "\(method) \(path)" }

  /// The text an owner file is expected to contain for this route.
  public var pathLiteralPrefix: String {
    if let ownerMarker { return ownerMarker }
    guard let parameter = path.range(of: "/{") else { return path }
    return String(path[path.startIndex..<parameter.lowerBound])
  }
}

public enum RielaWebAPIRouteTable {
  private static let projection = "Sources/RielaAppSupport/RielaWebAPIProjection.swift"
  private static let serveInstances = "Sources/RielaCLI/ServeWebHost+Instances.swift"
  private static let serveInstanceCreation = "Sources/RielaCLI/ServeWebHost+InstanceCreation.swift"
  private static let desktopInstances = "Sources/RielaApp/RielaAppInstanceAPI.swift"
  private static let desktopWorkerSettings = "Sources/RielaApp/RielaAppWorkerSettingsAPI.swift"
  private static let desktopRequest = "Sources/RielaApp/RielaDesktopRequest.swift"
  private static let editor = "Sources/RielaCLI/RielaWebWorkflowRuntime.swift"
  private static let editorEvidence = "Sources/RielaCLI/WebWorkflowRequestHandler+RunEvidence.swift"
  private static let passkeys = "Sources/RielaServer/RielaPasskeyService.swift"

  /// Read projections shared by `riela serve` and the desktop host.
  public static let sharedProjection: [RielaWebAPIRoute] = [
    .init(method: "GET", path: "/api/v1/bootstrap", owner: projection),
    .init(method: "GET", path: "/api/v1/workflows/sources", owner: projection),
    .init(method: "GET", path: "/api/v1/workflows/sources/{sourceId}/definition", owner: projection),
    .init(
      method: "GET",
      path: "/api/v1/instances/{identity}/executions",
      owner: projection,
      ownerMarker: #"components[4] == "executions""#
    ),
    .init(
      method: "GET",
      path: "/api/v1/instances/{identity}/executions/{sessionId}",
      owner: projection,
      ownerMarker: #"components[0...2] == ["api", "v1", "instances"]"#
    ),
    .init(
      method: "GET",
      path: "/api/v1/executions/{sessionId}",
      owner: projection,
      ownerMarker: #"["api", "v1", "executions"]"#
    )
  ]

  /// Instance writes. Both hosts serve the same two routes with their own
  /// runtime; the desktop owner is checked separately by the gate.
  public static let instanceWrites: [RielaWebAPIRoute] = [
    .init(method: "POST", path: "/api/v1/instances", owner: serveInstanceCreation),
    .init(
      method: "POST",
      path: "/api/v1/instances/{identity}/actions",
      owner: serveInstances,
      ownerMarker: #"parts[4] == "actions""#
    )
  ]

  public static let desktopOnly: [RielaWebAPIRoute] = [
    .init(method: "GET", path: "/api/v1/settings/workers", owner: desktopWorkerSettings),
    .init(method: "PUT", path: "/api/v1/settings/workers", owner: desktopWorkerSettings),
    .init(method: "POST", path: "/api/v1/settings/worker-credentials", owner: desktopRequest)
  ]

  public static let workflowEditor: [RielaWebAPIRoute] = [
    .init(method: "POST", path: "/api/v1/workflow-editor/node-settings", owner: editor),
    .init(method: "POST", path: "/api/v1/workflow-editor/definition", owner: editor),
    .init(method: "POST", path: "/api/v1/workflow-editor/launches", owner: editor),
    .init(method: "GET", path: "/api/v1/workflow-editor/launches/{launchId}", owner: editor),
    .init(method: "POST", path: "/api/v1/workflow-editor/generations", owner: editor),
    .init(method: "GET", path: "/api/v1/workflow-editor/generations/{generationId}", owner: editor),
    .init(method: "DELETE", path: "/api/v1/workflow-editor/generations/{generationId}", owner: editor),
    .init(
      method: "GET",
      path: "/api/v1/workflow-editor/runs/{sessionId}",
      owner: editorEvidence,
      ownerMarker: "webWorkflowEditorRunEvidence"
    ),
    .init(
      method: "GET",
      path: "/api/v1/workflow-editor/runs/{sessionId}/steps/{executionId}",
      owner: editorEvidence,
      ownerMarker: #"parts[5] == "steps""#
    ),
    .init(
      method: "POST",
      path: "/api/v1/workflows/sources/{sourceId}/editable-copy",
      owner: editor,
      ownerMarker: #"parts[5] == "editable-copy""#
    )
  ]

  public static let passkeyAuth: [RielaWebAPIRoute] = [
    .init(method: "GET", path: "/api/v1/auth/status", owner: passkeys),
    .init(method: "POST", path: "/api/v1/auth/register/options", owner: passkeys),
    .init(method: "POST", path: "/api/v1/auth/register/finish", owner: passkeys),
    .init(method: "POST", path: "/api/v1/auth/login/options", owner: passkeys),
    .init(method: "POST", path: "/api/v1/auth/login/finish", owner: passkeys),
    .init(method: "POST", path: "/api/v1/auth/device/start", owner: passkeys),
    .init(method: "POST", path: "/api/v1/auth/device/info", owner: passkeys),
    .init(method: "POST", path: "/api/v1/auth/device/poll", owner: passkeys),
    .init(method: "POST", path: "/api/v1/auth/device/cancel", owner: passkeys),
    .init(method: "POST", path: "/api/v1/auth/logout", owner: passkeys)
  ]

  public static let all: [RielaWebAPIRoute] =
    sharedProjection + instanceWrites + desktopOnly + workflowEditor + passkeyAuth

  /// The desktop host serves the instance writes from its own file.
  public static let desktopInstanceWriteOwner = desktopInstances

  /// Path literals that guard a whole prefix rather than serve a route.
  public static let prefixGuards: Set<String> = [
    "/api/v1",
    "/api/v1/",
    "/api/v1/auth/",
    "/api/v1/workflow-editor/launches/",
    "/api/v1/workflow-editor/runs/",
    "/api/v1/workflow-editor/generations/"
  ]
}
