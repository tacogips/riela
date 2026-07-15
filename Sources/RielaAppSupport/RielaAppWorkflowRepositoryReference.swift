#if os(macOS)
import Foundation

public enum RielaAppWorkflowRepositoryReferenceError: Error, LocalizedError, Equatable {
  case unsupportedRepository(String)
  case unsafeRepository(String)

  public var errorDescription: String? {
    switch self {
    case let .unsupportedRepository(value):
      "Repository must be a public GitHub repository URL like https://github.com/owner/repo: \(value)"
    case let .unsafeRepository(value):
      "Repository reference contains unsafe components: \(value)"
    }
  }
}

public struct RielaAppWorkflowRepositoryReference: Codable, Equatable, Sendable {
  public var owner: String
  public var repository: String
  public var branch: String?

  public init(owner: String, repository: String, branch: String? = nil) {
    self.owner = owner
    self.repository = repository
    self.branch = branch
  }

  public var id: String {
    guard let branch else {
      return "\(owner)/\(repository)"
    }
    return "\(owner)/\(repository)@\(branch)"
  }

  public var cloneURL: String {
    "https://github.com/\(owner)/\(repository).git"
  }

  public var webURL: String {
    "https://github.com/\(owner)/\(repository)"
  }

  public static func parse(_ rawValue: String) throws -> RielaAppWorkflowRepositoryReference {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      throw RielaAppWorkflowRepositoryReferenceError.unsupportedRepository(rawValue)
    }
    let parts: [String]
    if value.lowercased().hasPrefix("https://") {
      guard let components = URLComponents(string: value),
        components.scheme == "https",
        components.host == "github.com" else {
        throw RielaAppWorkflowRepositoryReferenceError.unsupportedRepository(rawValue)
      }
      parts = components.path.split(separator: "/").map(String.init)
    } else if value.contains("://") || value.contains("@") || value.lowercased().hasPrefix("github.com/") {
      throw RielaAppWorkflowRepositoryReferenceError.unsupportedRepository(rawValue)
    } else {
      parts = value.split(separator: "/").map(String.init)
    }
    let owner: String
    var repository: String
    var branch: String?
    switch parts.count {
    case 2:
      owner = parts[0]
      repository = parts[1]
    case 4 where parts[2] == "tree":
      owner = parts[0]
      repository = parts[1]
      branch = parts[3]
    default:
      throw RielaAppWorkflowRepositoryReferenceError.unsupportedRepository(rawValue)
    }
    if repository.lowercased().hasSuffix(".git") {
      repository = String(repository.dropLast(4))
    }
    let components = [owner, repository] + (branch.map { [$0] } ?? [])
    guard components.allSatisfy(isSafeComponent) else {
      throw RielaAppWorkflowRepositoryReferenceError.unsafeRepository(rawValue)
    }
    return RielaAppWorkflowRepositoryReference(owner: owner, repository: repository, branch: branch)
  }

  private static func isSafeComponent(_ value: String) -> Bool {
    guard !value.isEmpty, value != ".", value != ".." else {
      return false
    }
    return value.allSatisfy { character in
      character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
    }
  }
}
#endif
