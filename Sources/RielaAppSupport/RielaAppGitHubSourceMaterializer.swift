#if os(macOS)
import Foundation

public enum RielaAppGitHubSourceMaterializerError: Error, LocalizedError, Equatable {
  case unsupportedURL(String)
  case unsafeURL(String)
  case gitFailed(String)
  case missingCheckout(String)

  public var errorDescription: String? {
    switch self {
    case let .unsupportedURL(value):
      "GitHub URL must point to a workflow or package directory: \(value)"
    case let .unsafeURL(value):
      "GitHub URL contains unsafe path components: \(value)"
    case let .gitFailed(message):
      "GitHub checkout failed: \(message)"
    case let .missingCheckout(path):
      "GitHub checkout did not create the requested directory: \(path)"
    }
  }
}

public struct RielaAppGitHubDirectoryReference: Equatable, Sendable {
  public var owner: String
  public var repository: String
  public var branch: String
  public var sourcePath: String

  public init(owner: String, repository: String, branch: String, sourcePath: String) {
    self.owner = owner
    self.repository = repository
    self.branch = branch
    self.sourcePath = sourcePath
  }

  public var cloneURL: String {
    "https://github.com/\(owner)/\(repository).git"
  }
}

public struct RielaAppMaterializedGitHubSource: Equatable, Sendable {
  public var sourceURL: URL
  public var temporaryRoot: URL

  public init(sourceURL: URL, temporaryRoot: URL) {
    self.sourceURL = sourceURL
    self.temporaryRoot = temporaryRoot
  }
}

public struct RielaAppGitHubSourceMaterializer: Sendable {
  public var temporaryRoot: URL
  public var gitExecutable: String

  public init(
    temporaryRoot: URL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RielaApp/github-imports", isDirectory: true),
    gitExecutable: String = "git"
  ) {
    self.temporaryRoot = temporaryRoot
    self.gitExecutable = gitExecutable
  }

  public static func parseDirectoryReference(_ value: String) throws -> RielaAppGitHubDirectoryReference {
    guard let components = URLComponents(string: value),
      components.scheme == "https",
      components.host == "github.com" else {
      throw RielaAppGitHubSourceMaterializerError.unsupportedURL(value)
    }
    let parts = components.path.split(separator: "/").map(String.init)
    guard parts.count >= 5, parts[2] == "tree" else {
      throw RielaAppGitHubSourceMaterializerError.unsupportedURL(value)
    }
    let owner = parts[0]
    let repository = parts[1]
    let branch = parts[3]
    let sourcePath = parts.dropFirst(4).joined(separator: "/")
    let safeParts = [owner, repository, branch] + sourcePath.split(separator: "/").map(String.init)
    guard safeParts.allSatisfy(isSafeComponent) else {
      throw RielaAppGitHubSourceMaterializerError.unsafeURL(value)
    }
    return RielaAppGitHubDirectoryReference(
      owner: owner,
      repository: repository,
      branch: branch,
      sourcePath: sourcePath
    )
  }

  public func materialize(_ value: String) throws -> RielaAppMaterializedGitHubSource {
    let reference = try Self.parseDirectoryReference(value)
    let root = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let checkout = root.appendingPathComponent("checkout", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    do {
      try runGit([
        "clone",
        "--depth", "1",
        "--filter=blob:none",
        "--sparse",
        "--branch", reference.branch,
        reference.cloneURL,
        checkout.path
      ])
      try runGit(["-C", checkout.path, "sparse-checkout", "set", reference.sourcePath])
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
    let sourceURL = checkout.appendingPathComponent(reference.sourcePath, isDirectory: true)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      try? FileManager.default.removeItem(at: root)
      throw RielaAppGitHubSourceMaterializerError.missingCheckout(sourceURL.path)
    }
    return RielaAppMaterializedGitHubSource(sourceURL: sourceURL, temporaryRoot: root)
  }

  private func runGit(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [gitExecutable] + arguments
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    do {
      try process.run()
    } catch {
      throw RielaAppGitHubSourceMaterializerError.gitFailed(error.localizedDescription)
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
      let stderr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      throw RielaAppGitHubSourceMaterializerError.gitFailed(stderr?.isEmpty == false ? stderr ?? "" : "exit \(process.terminationStatus)")
    }
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
