import Foundation
import RielaAddons

struct GitHubPackageReference {
  let owner: String
  let repository: String
  let branch: String?
  let packagePath: String?

  struct Checkout {
    let temporaryRoot: URL
    let packageDirectory: URL
    let revision: String
  }

  static func parse(_ value: String) throws -> Self? {
    guard let url = URL(string: value), url.scheme == "https", url.host == "github.com" else {
      return nil
    }
    let components = url.pathComponents.filter { $0 != "/" }
    guard url.user == nil, url.password == nil, url.port == nil,
      url.query == nil, url.fragment == nil,
      components.count == 2 || (components.count >= 5 && components[2] == "tree") else {
      throw CLIUsageError("package update requires a GitHub repository or package directory URL")
    }
    guard components.allSatisfy(isSafeComponent) else {
      throw CLIUsageError("package update GitHub URL contains unsafe path components")
    }
    return Self(
      owner: components[0],
      repository: components[1].hasSuffix(".git") ? String(components[1].dropLast(4)) : components[1],
      branch: components.count > 2 ? components[3] : nil,
      packagePath: components.count > 2 ? components.dropFirst(4).joined(separator: "/") : nil
    )
  }

  func checkout(workingDirectory: URL, revision: String? = nil) throws -> Checkout {
    if let revision, revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) == nil {
      throw CLIUsageError("package ci locked GitHub revision must be a full commit SHA")
    }
    let temporaryRoot = workingDirectory
      .appendingPathComponent("tmp/riela-package-update", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let repositoryRoot = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    do {
      var arguments = ["clone", "--quiet", "--depth", "1", "--filter=blob:none"]
      if packagePath != nil {
        arguments.append("--sparse")
      }
      if revision != nil {
        arguments.append("--no-checkout")
      } else if let branch {
        arguments += ["--branch", branch]
      }
      arguments += ["https://github.com/\(owner)/\(repository).git", repositoryRoot.path]
      try runGit(arguments, workingDirectory: workingDirectory)
      if let revision {
        try runGit(["-C", repositoryRoot.path, "fetch", "--quiet", "--depth", "1", "origin", revision], workingDirectory: workingDirectory)
        try runGit(["-C", repositoryRoot.path, "checkout", "--quiet", "--detach", revision], workingDirectory: workingDirectory)
      }
      if let packagePath {
        try runGit(["-C", repositoryRoot.path, "sparse-checkout", "set", "--", packagePath], workingDirectory: workingDirectory)
      }
      let resolvedRevision = try runGit(["-C", repositoryRoot.path, "rev-parse", "HEAD"], workingDirectory: workingDirectory)
      let packageDirectory: URL
      if let packagePath {
        packageDirectory = repositoryRoot.appendingPathComponent(packagePath, isDirectory: true)
      } else {
        packageDirectory = temporaryRoot.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.copyItem(at: repositoryRoot, to: packageDirectory)
        try FileManager.default.removeItem(at: packageDirectory.appendingPathComponent(".git"))
      }
      guard FileManager.default.fileExists(
        atPath: packageDirectory.appendingPathComponent(WorkflowPackageArchiveManager.manifestFileName).path
      ) else {
        throw CLIUsageError("GitHub URL does not contain a riela-package.json at \(packagePath ?? ".")")
      }
      return Checkout(temporaryRoot: temporaryRoot, packageDirectory: packageDirectory, revision: resolvedRevision)
    } catch {
      try? FileManager.default.removeItem(at: temporaryRoot)
      throw error
    }
  }

  private static func isSafeComponent(_ value: String) -> Bool {
    guard !value.isEmpty, value != ".", value != "..", value.unicodeScalars.count <= 120 else {
      return false
    }
    return value.unicodeScalars.allSatisfy { scalar in
      let code = scalar.value
      return (65...90).contains(code) || (97...122).contains(code) || (48...57).contains(code)
        || scalar == "." || scalar == "_" || scalar == "-"
    }
  }

  @discardableResult
  private func runGit(_ arguments: [String], workingDirectory: URL) throws -> String {
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    let configuredExecutable = environment["RIELA_GIT_EXECUTABLE"] ?? ""
    let executable = configuredExecutable.isEmpty ? "git" : configuredExecutable
    let gitURL: URL
    if executable.contains("/") {
      gitURL = URL(fileURLWithPath: executable, relativeTo: workingDirectory).standardizedFileURL
    } else if !executable.contains("/"), let path = environment["PATH"]?.split(separator: ":").first(where: { directory in
      FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: String(directory)).appendingPathComponent(executable).path)
    }) {
      gitURL = URL(fileURLWithPath: String(path)).appendingPathComponent(executable)
    } else {
      throw CLIUsageError("git executable not found: \(executable); set RIELA_GIT_EXECUTABLE or PATH")
    }
    guard FileManager.default.isExecutableFile(atPath: gitURL.path) else {
      throw CLIUsageError("git executable is not executable: \(gitURL.path)")
    }
    let process = Process()
    process.executableURL = gitURL
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = workingDirectory
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    // Drain while Git is running: waiting first can deadlock on a full pipe.
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard process.terminationStatus == 0 else {
      throw CLIUsageError("package update GitHub checkout failed: \(message)")
    }
    return message
  }
}
