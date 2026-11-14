import Foundation

/// How an attempt's workspace is isolated from other attempts.
public enum RepositoryIsolation: String, Codable, CaseIterable, Sendable {
  /// Today's cooperative shared-workspace behavior.
  case shared
  /// A git worktree per attempt. The runtime that creates it lands in P4.
  case worktree
}

/// Repository facts a task carries. The lifecycle never reads these; only the
/// repository context adapter does (design section 9).
public struct RepositoryContext: Codable, Equatable, Sendable {
  public var root: String
  public var baseRevision: String?
  public var isolation: RepositoryIsolation
  /// Paths an attempt may write, relative to `root`. Empty means unrestricted.
  public var writeScopes: [String]

  public init(
    root: String,
    baseRevision: String? = nil,
    isolation: RepositoryIsolation = .shared,
    writeScopes: [String] = []
  ) {
    self.root = root
    self.baseRevision = baseRevision
    self.isolation = isolation
    self.writeScopes = writeScopes
  }
}

/// Domain facts enter the lifecycle here and nowhere else (design section 9).
/// P0 declares the repository case only; further kinds arrive with their
/// adapters.
public enum ContextBinding: Codable, Equatable, Sendable {
  case repository(RepositoryContext)

  private enum CodingKeys: String, CodingKey {
    case kind
    case repository
  }

  private enum Kind: String, Codable {
    case repository
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .repository:
      self = .repository(try container.decode(RepositoryContext.self, forKey: .repository))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .repository(context):
      try container.encode(Kind.repository, forKey: .kind)
      try container.encode(context, forKey: .repository)
    }
  }
}

/// Where an attempt actually ran. P4 fills it in; P0 only carries it.
public struct IsolationRef: Codable, Equatable, Sendable {
  public var path: String
  public var branch: String?
  public var baseRevision: String?

  public init(path: String, branch: String? = nil, baseRevision: String? = nil) {
    self.path = path
    self.branch = branch
    self.baseRevision = baseRevision
  }
}
