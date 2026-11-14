import Foundation

/// The control surfaces Riela exposes. One catalog row per public operation
/// declares, for every surface, whether the operation is implemented there,
/// deliberately absent, or accepted-but-not-yet-built.
///
/// `design-docs/specs/design-control-surface-parity.md` section 2.1 is the
/// source of truth for this model. The catalog is plain data: it imports
/// nothing from `RielaCLI`, `RielaGraphQL`, `RielaAppSupport`, or
/// `RielaServer`, so each of those can import `RielaCore` and gate itself
/// against it.
public enum SurfaceName: String, Codable, Sendable, CaseIterable {
  case cli
  case graphql
  case webAPI
  case desktop
  case library
  case skill
}

/// Availability of one operation on one surface.
///
/// `blocked` is an accepted gap waiting on named evidence (a plan, an issue,
/// a dependency). `excluded` is a decision that the operation does not belong
/// on that surface, and carries the design section that made the decision.
public enum SurfaceAvailability: Codable, Sendable, Equatable {
  case implemented
  case blocked(evidence: String)
  case excluded(reason: String, design: String)

  public var isImplemented: Bool {
    if case .implemented = self { return true }
    return false
  }
}

public enum SurfaceGraphQLRoot: String, Codable, Sendable, CaseIterable {
  case query = "Query"
  case mutation = "Mutation"
}

/// A CLI command path (`riela workflow run`) plus the option names the catalog
/// claims for it. Options are the tokens skills are allowed to document.
public struct SurfaceCLIBinding: Codable, Sendable, Equatable {
  public var path: [String]
  public var options: [String]

  public init(path: [String], options: [String] = []) {
    self.path = path
    self.options = options
  }

  public var command: String { path.joined(separator: " ") }
}

public struct SurfaceGraphQLBinding: Codable, Sendable, Equatable {
  public var root: SurfaceGraphQLRoot
  public var field: String

  public init(root: SurfaceGraphQLRoot, field: String) {
    self.root = root
    self.field = field
  }

  /// The identity the GraphQL gate compares against the schema.
  public var qualifiedField: String { "\(root.rawValue).\(field)" }
}

/// A declared `/api/v1` route. Parameter segments use `{name}` so the declared
/// route tables (design delta D7) can be compared with the catalog without
/// depending on a concrete identity.
public struct SurfaceWebAPIBinding: Codable, Sendable, Equatable {
  public var method: String
  public var path: String

  public init(method: String, path: String) {
    self.method = method
    self.path = path
  }

  public var route: String { "\(method) \(path)" }
}

public struct SurfaceLibraryBinding: Codable, Sendable, Equatable {
  public var type: String
  public var function: String

  public init(type: String, function: String) {
    self.type = type
    self.function = function
  }

  public var qualifiedName: String { "\(type).\(function)" }
}

public struct SurfaceOperation: Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case query
    case mutation
    case stream
    case process
  }

  /// Stable id naming the runtime capability, not a command (`session.rerun`).
  public var id: String
  public var family: String
  public var kind: Kind
  public var surfaces: [SurfaceName: SurfaceAvailability]
  public var cli: SurfaceCLIBinding?
  public var graphql: SurfaceGraphQLBinding?
  public var webAPI: SurfaceWebAPIBinding?
  public var library: SurfaceLibraryBinding?
  public var skills: [String]
  public var designSource: String

  public init(
    id: String,
    family: String,
    kind: Kind,
    surfaces: [SurfaceName: SurfaceAvailability],
    cli: SurfaceCLIBinding? = nil,
    graphql: SurfaceGraphQLBinding? = nil,
    webAPI: SurfaceWebAPIBinding? = nil,
    library: SurfaceLibraryBinding? = nil,
    skills: [String] = [],
    designSource: String
  ) {
    self.id = id
    self.family = family
    self.kind = kind
    self.surfaces = surfaces
    self.cli = cli
    self.graphql = graphql
    self.webAPI = webAPI
    self.library = library
    self.skills = skills
    self.designSource = designSource
  }

  public func availability(on surface: SurfaceName) -> SurfaceAvailability? {
    surfaces[surface]
  }

  public func isImplemented(on surface: SurfaceName) -> Bool {
    surfaces[surface]?.isImplemented ?? false
  }
}

/// One violation of a catalog invariant or of a surface gate.
public struct SurfaceParityViolation: Sendable, Equatable, CustomStringConvertible {
  public var surface: SurfaceName?
  public var subject: String
  public var reason: String

  public init(surface: SurfaceName?, subject: String, reason: String) {
    self.surface = surface
    self.subject = subject
    self.reason = reason
  }

  public var description: String {
    let prefix = surface.map { "[\($0.rawValue)] " } ?? ""
    return "\(prefix)\(subject): \(reason)"
  }
}

public enum SurfaceCatalog {
  /// Surfaces every row must declare. `desktop` and `skill` are declared only
  /// where the operation actually reaches them.
  public static let requiredSurfaces: [SurfaceName] = [.cli, .graphql, .webAPI, .library]

  public static func operation(id: String) -> SurfaceOperation? {
    all.first { $0.id == id }
  }

  public static func operations(inFamily family: String) -> [SurfaceOperation] {
    all.filter { $0.family == family }
  }

  /// Rows that claim `surface` as implemented.
  public static func implemented(on surface: SurfaceName) -> [SurfaceOperation] {
    all.filter { $0.isImplemented(on: surface) }
  }

  public static var declaredCLICommands: Set<String> {
    Set(all.compactMap { $0.cli?.command })
  }

  public static var declaredGraphQLFields: Set<String> {
    Set(all.compactMap { $0.graphql?.qualifiedField })
  }

  public static var declaredWebAPIRoutes: Set<String> {
    Set(all.compactMap { $0.webAPI?.route })
  }

  public static var declaredLibraryFunctions: Set<String> {
    Set(all.compactMap { $0.library?.qualifiedName })
  }

  public static var declaredCLIOptions: Set<String> {
    Set(all.compactMap(\.cli).flatMap(\.options))
  }

  /// Structural invariants that hold independently of any surface: unique ids
  /// and bindings, complete availability declarations, and evidence or reasons
  /// on every non-implemented required surface.
  public static func invariantViolations() -> [SurfaceParityViolation] {
    var violations: [SurfaceParityViolation] = []
    violations.append(contentsOf: duplicates(all.map(\.id), subjectPrefix: "operation id"))
    violations.append(contentsOf: duplicates(all.compactMap { $0.cli?.command }, subjectPrefix: "cli command"))
    violations.append(contentsOf: duplicates(
      all.compactMap { $0.graphql?.qualifiedField },
      subjectPrefix: "graphql field"
    ))
    violations.append(contentsOf: duplicates(all.compactMap { $0.webAPI?.route }, subjectPrefix: "web api route"))
    violations.append(contentsOf: duplicates(
      all.compactMap { $0.library?.qualifiedName },
      subjectPrefix: "library function"
    ))
    for operation in all {
      violations.append(contentsOf: invariantViolations(for: operation))
    }
    return violations
  }

  private static func invariantViolations(for operation: SurfaceOperation) -> [SurfaceParityViolation] {
    var violations: [SurfaceParityViolation] = []
    if operation.designSource.isEmpty {
      violations.append(.init(surface: nil, subject: operation.id, reason: "empty designSource"))
    }
    if operation.family.isEmpty || !operation.id.hasPrefix("\(operation.family).") {
      violations.append(.init(
        surface: nil,
        subject: operation.id,
        reason: "id must be namespaced by its family '\(operation.family)'"
      ))
    }
    for surface in requiredSurfaces {
      guard let availability = operation.surfaces[surface] else {
        violations.append(.init(surface: surface, subject: operation.id, reason: "missing availability declaration"))
        continue
      }
      switch availability {
      case .implemented:
        if binding(of: operation, on: surface) == nil {
          violations.append(.init(surface: surface, subject: operation.id, reason: "implemented without a binding"))
        }
      case let .blocked(evidence):
        if evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          violations.append(.init(surface: surface, subject: operation.id, reason: "blocked without evidence"))
        }
      case let .excluded(reason, design):
        if reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          violations.append(.init(surface: surface, subject: operation.id, reason: "excluded without a reason"))
        }
        if design.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          violations.append(.init(surface: surface, subject: operation.id, reason: "excluded without a design link"))
        }
      }
      if !availability.isImplemented, binding(of: operation, on: surface) != nil {
        violations.append(.init(
          surface: surface,
          subject: operation.id,
          reason: "carries a binding while declared unavailable"
        ))
      }
    }
    return violations
  }

  private static func binding(of operation: SurfaceOperation, on surface: SurfaceName) -> String? {
    switch surface {
    case .cli: return operation.cli?.command
    case .graphql: return operation.graphql?.qualifiedField
    case .webAPI: return operation.webAPI?.route
    case .library: return operation.library?.qualifiedName
    case .desktop, .skill: return nil
    }
  }

  private static func duplicates(_ values: [String], subjectPrefix: String) -> [SurfaceParityViolation] {
    var seen: Set<String> = []
    var reported: Set<String> = []
    var violations: [SurfaceParityViolation] = []
    for value in values where !seen.insert(value).inserted {
      guard reported.insert(value).inserted else { continue }
      violations.append(.init(surface: nil, subject: "\(subjectPrefix) '\(value)'", reason: "declared by more than one row"))
    }
    return violations
  }

  /// Shared bijection check used by every surface gate: the surface's actual
  /// operations must equal the catalog rows that claim it.
  public static func bijectionViolations(
    surface: SurfaceName,
    actual: Set<String>,
    declared: Set<String>
  ) -> [SurfaceParityViolation] {
    var violations: [SurfaceParityViolation] = []
    for missing in actual.subtracting(declared).sorted() {
      violations.append(.init(
        surface: surface,
        subject: missing,
        reason: "exists on the surface but has no catalog row"
      ))
    }
    for extra in declared.subtracting(actual).sorted() {
      violations.append(.init(
        surface: surface,
        subject: extra,
        reason: "declared implemented in the catalog but absent from the surface"
      ))
    }
    return violations
  }
}
