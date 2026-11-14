import Foundation

/// Authoring support for `SurfaceCatalog.all`. Row files stay declarative; the
/// repeated availability reasons from design section 2.6 live here once.
public extension SurfaceCatalog {
  static let controlSurfaceDesign = "design-docs/specs/design-control-surface-parity.md"
  static let workRuntimeDesign = "design-docs/specs/design-work-runtime-consolidation.md"
  static let workRuntimeP0Plan = "impl-plans/active/work-runtime-p0-model-and-store.md"
  static let managerControlPlaneDesign = "design-docs/specs/design-graphql-manager-control-plane.md"
}

/// The exclusion reasons design section 2.6 assigns to whole families, so a row
/// states only what is specific to it.
enum SurfaceExclusion {
  static func localProcess(_ what: String) -> SurfaceAvailability {
    .excluded(
      reason: "\(what) is a local process and filesystem operation; design 2.6 keeps it off the control plane",
      design: "\(SurfaceCatalog.controlSurfaceDesign)#26-closing-the-current-gaps"
    )
  }

  static func consoleOnly(_ what: String) -> SurfaceAvailability {
    .excluded(
      reason: "\(what) is a console-only operation; it has no shell face",
      design: "\(SurfaceCatalog.controlSurfaceDesign)#24-retire-the-parallel-console-surface"
    )
  }

  static func notAConsoleOperation(_ what: String) -> SurfaceAvailability {
    .excluded(
      reason: "\(what) is not a console operation; the web and desktop consoles never call it",
      design: "\(SurfaceCatalog.controlSurfaceDesign)#24-retire-the-parallel-console-surface"
    )
  }

  static func notALibraryEntryPoint(_ what: String) -> SurfaceAvailability {
    .excluded(
      reason: "\(what) is not part of the embedding facade; design 2.6 fixes the facade at six entry points",
      design: "\(SurfaceCatalog.controlSurfaceDesign)#26-closing-the-current-gaps"
    )
  }

  static let loopNamesRetired = SurfaceAvailability.excluded(
    reason: "loop operations do not gain GraphQL under the loop names; they arrive as task operations in Work Runtime P2",
    design: "\(SurfaceCatalog.workRuntimeDesign)"
  )

  static let memoryStaysLocal = SurfaceAvailability.excluded(
    reason: "memory stays CLI and library only; its payloads are local files the control plane does not proxy",
    design: "\(SurfaceCatalog.controlSurfaceDesign)#26-closing-the-current-gaps"
  )

  static let specialistFoldsIntoTask = SurfaceAvailability.excluded(
    reason: "specialist folds into task serve in the Work Runtime design; no new GraphQL is added under the specialist name",
    design: "\(SurfaceCatalog.workRuntimeDesign)"
  )

  static let supervisionDeleted = SurfaceAvailability.excluded(
    reason: "auto-improve supervision is deleted by the Work Runtime design; no supervision type enters the schema",
    design: "\(SurfaceCatalog.workRuntimeDesign)"
  )

  static func byteTransfer(_ what: String) -> SurfaceAvailability {
    .excluded(
      reason: "\(what) is a byte-transfer route, not a control-plane operation",
      design: "\(SurfaceCatalog.controlSurfaceDesign)#24-retire-the-parallel-console-surface"
    )
  }

  static func authHandshake(_ what: String) -> SurfaceAvailability {
    .excluded(
      reason: "\(what) is part of the credential handshake that authenticates GraphQL itself",
      design: "\(SurfaceCatalog.controlSurfaceDesign)#24-retire-the-parallel-console-surface"
    )
  }
}

/// Availability defaults for a family of rows.
struct SurfaceRowDefaults {
  var cli: SurfaceAvailability
  var graphql: SurfaceAvailability
  var webAPI: SurfaceAvailability
  var library: SurfaceAvailability
  var design: String = SurfaceCatalog.controlSurfaceDesign
  var skills: [String] = []
}

func surfaceRow(
  _ defaults: SurfaceRowDefaults,
  id: String,
  family: String,
  kind: SurfaceOperation.Kind,
  cli: String? = nil,
  cliOptions: [String] = [],
  cliState: SurfaceAvailability? = nil,
  graphql: SurfaceGraphQLBinding? = nil,
  graphqlState: SurfaceAvailability? = nil,
  web: SurfaceWebAPIBinding? = nil,
  webState: SurfaceAvailability? = nil,
  library: SurfaceLibraryBinding? = nil,
  libraryState: SurfaceAvailability? = nil,
  desktop: SurfaceAvailability? = nil,
  skills: [String]? = nil,
  design: String? = nil
) -> SurfaceOperation {
  var surfaces: [SurfaceName: SurfaceAvailability] = [
    .cli: cliState ?? (cli == nil ? defaults.cli : .implemented),
    .graphql: graphqlState ?? (graphql == nil ? defaults.graphql : .implemented),
    .webAPI: webState ?? (web == nil ? defaults.webAPI : .implemented),
    .library: libraryState ?? (library == nil ? defaults.library : .implemented)
  ]
  if let desktop {
    surfaces[.desktop] = desktop
  }
  let resolvedSkills = skills ?? defaults.skills
  if !resolvedSkills.isEmpty {
    surfaces[.skill] = .implemented
  }
  return SurfaceOperation(
    id: id,
    family: family,
    kind: kind,
    surfaces: surfaces,
    cli: cli.map { SurfaceCLIBinding(path: $0.split(separator: " ").map(String.init), options: cliOptions) },
    graphql: graphql,
    webAPI: web,
    library: library,
    skills: resolvedSkills,
    designSource: design ?? defaults.design
  )
}

func graphQLQuery(_ field: String) -> SurfaceGraphQLBinding {
  SurfaceGraphQLBinding(root: .query, field: field)
}

func graphQLMutation(_ field: String) -> SurfaceGraphQLBinding {
  SurfaceGraphQLBinding(root: .mutation, field: field)
}

func webRoute(_ method: String, _ path: String) -> SurfaceWebAPIBinding {
  SurfaceWebAPIBinding(method: method, path: path)
}

func libraryEntryPoint(_ function: String, type: String = "RielaLibrary") -> SurfaceLibraryBinding {
  SurfaceLibraryBinding(type: type, function: function)
}
