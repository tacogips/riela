#if os(macOS)
import Foundation

public enum RielaAppWorkflowRepositoryCatalogError: Error, LocalizedError, Equatable {
  case gitFailed(String)
  case missingCheckout(String)

  public var errorDescription: String? {
    switch self {
    case let .gitFailed(message):
      "Repository fetch failed: \(message)"
    case let .missingCheckout(path):
      "Repository fetch did not produce a checkout: \(path)"
    }
  }
}

public struct RielaAppWorkflowRepositoryCatalogLoader: Sendable {
  public var cacheRoot: URL
  public var gitExecutable: String

  public init(cacheRoot: URL, gitExecutable: String = "git") {
    self.cacheRoot = cacheRoot
    self.gitExecutable = gitExecutable
  }

  public static func defaultCacheRoot(appRootURL: URL) -> URL {
    appRootURL.appendingPathComponent("marketplace-cache", isDirectory: true)
  }

  public func checkoutDirectory(for repository: RielaAppWorkflowRepositoryReference) -> URL {
    cacheRoot.appendingPathComponent(Self.cacheDirectoryName(for: repository), isDirectory: true)
  }

  public func loadCatalog(
    for repository: RielaAppWorkflowRepositoryReference,
    forceRefresh: Bool
  ) throws -> RielaAppWorkflowRepositoryCatalog {
    let checkout = checkoutDirectory(for: repository)
    if forceRefresh || !isUsableCheckout(checkout) {
      try? FileManager.default.removeItem(at: checkout)
      try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
      var arguments = ["clone", "--depth", "1"]
      if let branch = repository.branch {
        arguments += ["--branch", branch]
      }
      arguments += [repository.cloneURL, checkout.path]
      do {
        try runGit(arguments)
      } catch {
        try? FileManager.default.removeItem(at: checkout)
        throw error
      }
    }
    guard isUsableCheckout(checkout) else {
      throw RielaAppWorkflowRepositoryCatalogError.missingCheckout(checkout.path)
    }
    return RielaAppWorkflowRepositoryCatalog(
      repository: repository,
      workflows: RielaAppWorkflowRepositoryCatalogScanner.scan(
        repositoryRoot: checkout,
        repositoryId: repository.id
      )
    )
  }

  static func cacheDirectoryName(for repository: RielaAppWorkflowRepositoryReference) -> String {
    let mapped = repository.id.map { character in
      character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
        ? character
        : "-"
    }
    let sanitized = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
    return sanitized.isEmpty ? "repository" : sanitized
  }

  private func isUsableCheckout(_ checkout: URL) -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: checkout.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      return false
    }
    return FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".git").path)
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
      throw RielaAppWorkflowRepositoryCatalogError.gitFailed(error.localizedDescription)
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
      let stderr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      throw RielaAppWorkflowRepositoryCatalogError.gitFailed(
        stderr?.isEmpty == false ? stderr ?? "" : "exit \(process.terminationStatus)"
      )
    }
  }
}
#endif
