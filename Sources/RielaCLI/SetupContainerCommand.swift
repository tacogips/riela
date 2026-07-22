import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ArgumentParser
import RielaAdapters

public enum SetupContainerActionKind: String, Codable, Equatable, Sendable {
  case checkRuntime
  case downloadInstaller
  case verifyInstaller
  case openInstaller
  case installPackage
  case startService
}

public struct SetupContainerAction: Codable, Equatable, Sendable {
  public var kind: SetupContainerActionKind
  public var description: String
  public var command: [String]
  public var status: DoctorCheckStatus
}

public struct SetupContainerResult: Codable, Equatable, Sendable {
  public var dryRun: Bool
  public var accepted: Bool
  public var runtimePath: String?
  public var releaseURL: String
  public var installerAssetName: String?
  public var installerDownloadURL: String?
  public var installerPath: String?
  public var actions: [SetupContainerAction]
  public var script: String?
  public var nextStep: String?
}

public struct SetupContainerCommand: Sendable {
  static let releaseURL = "https://github.com/apple/container/releases/latest"
  static let releasesAPIURL = "https://api.github.com/repos/apple/container/releases/latest"
  static let defaultInstalledRuntimePath = "/usr/local/bin/container"
  static let installerPath = "/usr/sbin/installer"
  static let spctlPath = "/usr/sbin/spctl"

  public var runner: any LocalAgentProcessRunning
  public var releaseResolver: any SetupContainerReleaseResolving
  public var downloader: any SetupContainerDownloading

  public init(
    runner: any LocalAgentProcessRunning = FoundationLocalAgentProcessRunner(),
    releaseResolver: any SetupContainerReleaseResolving = GitHubSetupContainerReleaseResolver(),
    downloader: any SetupContainerDownloading = URLSessionSetupContainerDownloader()
  ) {
    self.runner = runner
    self.releaseResolver = releaseResolver
    self.downloader = downloader
  }

  public func run(_ options: CLICommandOptions) async -> CLICommandResult {
    do {
      let parsed = try SetupContainerOptions(arguments: options.arguments)
      let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
      let searchPath = executableSearchPath(environment: environment)
      let runtimePath = resolveExecutable("container", searchPath: searchPath)
      let dryRun = parsed.dryRun || (!parsed.yes && !parsed.openInstaller)
      var result = setupPlan(options: parsed, dryRun: dryRun, runtimePath: runtimePath)
      if parsed.openInstaller, !parsed.dryRun, runtimePath == nil {
        result = try await openInstaller(result: result, searchPath: searchPath, environment: environment)
      }
      if parsed.yes, !parsed.dryRun, runtimePath == nil {
        result = try await installAppleContainer(result: result, environment: environment)
      }
      if parsed.yes, !parsed.dryRun, let runtimePath {
        result = try await startContainerSystem(result: result, runtimePath: runtimePath)
      }
      return try render(result, output: options.output)
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  private func setupPlan(
    options: SetupContainerOptions,
    dryRun: Bool,
    runtimePath: String?
  ) -> SetupContainerResult {
    var actions: [SetupContainerAction] = [
      .init(
        kind: .checkRuntime,
        description: "Check whether Apple Container is already installed",
        command: ["command", "-v", "container"],
        status: runtimePath == nil ? .missing : .ok
      )
    ]
    if runtimePath == nil {
      actions.append(.init(
        kind: .downloadInstaller,
        description: "Download the latest signed Apple Container installer package",
        command: ["curl", "-L", "-o", "<downloaded-container.pkg>", Self.releaseURL],
        status: .warning
      ))
      actions.append(.init(
        kind: .verifyInstaller,
        description: "Verify the downloaded Apple Container installer signature",
        command: [Self.spctlPath, "--assess", "--type", "install", "<downloaded-container.pkg>"],
        status: .warning
      ))
      if options.openInstaller {
        actions.append(.init(
          kind: .openInstaller,
          description: "Open the downloaded signed installer with the macOS installer UI",
          command: ["open", "<downloaded-container.pkg>"],
          status: dryRun ? .warning : .unknown
        ))
      }
      actions.append(.init(
        kind: .installPackage,
        description: "Install the downloaded signed .pkg with the macOS installer",
        command: ["sudo", "installer", "-pkg", "<downloaded-container.pkg>", "-target", "/"],
        status: .warning
      ))
    }
    actions.append(.init(
      kind: .startService,
      description: "Start the Apple Container system service",
      command: [runtimePath ?? "container", "system", "start"],
      status: runtimePath == nil || dryRun ? .warning : .unknown
    ))
    return SetupContainerResult(
      dryRun: dryRun,
      accepted: options.yes,
      runtimePath: runtimePath,
      releaseURL: Self.releaseURL,
      installerAssetName: nil,
      installerDownloadURL: nil,
      installerPath: nil,
      actions: actions,
      script: options.printScript ? shellScript(options: options, runtimePath: runtimePath) : nil,
      nextStep: nextStep(runtimePath: runtimePath, dryRun: dryRun)
    )
  }

  private func installAppleContainer(
    result: SetupContainerResult,
    environment: [String: String]
  ) async throws -> SetupContainerResult {
    let prepared = try await prepareInstaller(result: result)
    let downloadedPackage = prepared.package
    let verified = try await verifyInstaller(result: prepared.result, package: downloadedPackage, environment: environment)
    var updated = verified.result
    guard verified.accepted else {
      updated.nextStep = "Apple Container installer signature verification failed."
      return updated
    }
    updated.actions = updated.actions.map { action in
      switch action.kind {
      case .installPackage:
        return SetupContainerAction(
          kind: action.kind,
          description: "Install \(updated.installerAssetName ?? downloadedPackage.lastPathComponent) with the macOS installer",
          command: [Self.installerPath, "-pkg", downloadedPackage.path, "-target", "/"],
          status: .unknown
        )
      case .startService:
        return SetupContainerAction(
          kind: action.kind,
          description: action.description,
          command: [Self.defaultInstalledRuntimePath, "system", "start"],
          status: .unknown
        )
      case .checkRuntime, .downloadInstaller, .verifyInstaller, .openInstaller:
        return action
      }
    }
    let installResult = try await runner.run(
      configuration: LocalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: Self.installerPath),
        arguments: ["-pkg", downloadedPackage.path, "-target", "/"],
        environment: environment
      ),
      stdin: "",
      deadline: nil
    )
    let installStatus: DoctorCheckStatus = installResult.terminationStatus == 0 ? .ok : .warning
    updated.actions = updated.actions.map { action in
      guard action.kind == .installPackage else {
        return action
      }
      return SetupContainerAction(
        kind: action.kind,
        description: action.description,
        command: action.command,
        status: installStatus
      )
    }
    guard installResult.terminationStatus == 0 else {
      updated.nextStep = installResult.stderr.isEmpty ? "Apple Container installer failed." : installResult.stderr
      return updated
    }
    return try await startContainerSystem(result: updated, runtimePath: Self.defaultInstalledRuntimePath)
  }

  private func startContainerSystem(
    result: SetupContainerResult,
    runtimePath: String
  ) async throws -> SetupContainerResult {
    var updated = result
    let processResult = try await runner.run(
      configuration: LocalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: runtimePath),
        arguments: ["system", "start"],
        environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
      ),
      stdin: "",
      deadline: nil
    )
    let status: DoctorCheckStatus = processResult.terminationStatus == 0 ? .ok : .warning
    updated.actions = updated.actions.map { action in
      guard action.kind == .startService else {
        return action
      }
      return SetupContainerAction(
        kind: action.kind,
        description: action.description,
        command: action.command,
        status: status
      )
    }
    updated.nextStep = processResult.terminationStatus == 0 ? "Run riela doctor to verify container readiness." : processResult.stderr
    return updated
  }

  private func openInstaller(
    result: SetupContainerResult,
    searchPath: [String],
    environment: [String: String]
  ) async throws -> SetupContainerResult {
    let prepared = try await prepareInstaller(result: result)
    let downloadedPackage = prepared.package
    let verified = try await verifyInstaller(result: prepared.result, package: downloadedPackage, environment: environment)
    var updated = verified.result
    guard verified.accepted else {
      updated.nextStep = "Apple Container installer signature verification failed."
      return updated
    }
    let openPath = resolveExecutable("open", searchPath: searchPath) ?? "/usr/bin/open"
    let processResult = try await runner.run(
      configuration: LocalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: openPath),
        arguments: [downloadedPackage.path],
        environment: environment
      ),
      stdin: "",
      deadline: nil
    )
    let status: DoctorCheckStatus = processResult.terminationStatus == 0 ? .ok : .warning
    updated.actions = updated.actions.map { action in
      guard action.kind == .openInstaller else {
        return action
      }
      return SetupContainerAction(
        kind: action.kind,
        description: action.description,
        command: [openPath, downloadedPackage.path],
        status: status
      )
    }
    updated.nextStep = processResult.terminationStatus == 0
      ? "Complete the macOS installer UI, then run riela setup container --yes to start the service."
      : processResult.stderr
    return updated
  }

  private func prepareInstaller(
    result: SetupContainerResult
  ) async throws -> (result: SetupContainerResult, package: URL) {
    var updated = result
    let release = try await releaseResolver.latestInstallerRelease()
    let downloadedPackage = try await downloader.downloadInstaller(from: release.downloadURL)
    updated.installerAssetName = release.assetName
    updated.installerDownloadURL = release.downloadURL.absoluteString
    updated.installerPath = downloadedPackage.path
    updated.actions = updated.actions.map { action in
      guard action.kind == .downloadInstaller else {
        return action
      }
      return SetupContainerAction(
        kind: action.kind,
        description: "Downloaded \(release.assetName)",
        command: ["curl", "-L", "-o", downloadedPackage.path, release.downloadURL.absoluteString],
        status: .ok
      )
    }
    return (updated, downloadedPackage)
  }

  private func verifyInstaller(
    result: SetupContainerResult,
    package: URL,
    environment: [String: String]
  ) async throws -> (result: SetupContainerResult, accepted: Bool) {
    var updated = result
    let verifyResult = try await runner.run(
      configuration: LocalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: Self.spctlPath),
        arguments: ["--assess", "--type", "install", package.path],
        environment: environment
      ),
      stdin: "",
      deadline: nil
    )
    let accepted = verifyResult.terminationStatus == 0
    updated.actions = updated.actions.map { action in
      guard action.kind == .verifyInstaller else {
        return action
      }
      return SetupContainerAction(
        kind: action.kind,
        description: action.description,
        command: [Self.spctlPath, "--assess", "--type", "install", package.path],
        status: accepted ? .ok : .warning
      )
    }
    if !accepted {
      updated.nextStep = verifyResult.stderr.isEmpty ? "Apple Container installer signature verification failed." : verifyResult.stderr
    }
    return (updated, accepted)
  }

  private func shellScript(options: SetupContainerOptions, runtimePath: String?) -> String {
    var lines = [
      "#!/bin/sh",
      "set -eu",
      "PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
      "export PATH",
      ""
    ]
    if let runtimePath {
      lines.append("\(shellQuoted(runtimePath)) system start")
      return lines.joined(separator: "\n") + "\n"
    }
    lines.append("release_api=\(shellQuoted(Self.releasesAPIURL))")
    lines.append(#"tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/riela-setup-container.XXXXXX")"#)
    if !options.openInstaller || options.yes {
      lines.append(#"trap 'rm -rf "$tmpdir"' EXIT"#)
    }
    lines.append(#"release_json="$tmpdir/release.json""#)
    lines.append(#"curl -fsSL "$release_api" -o "$release_json""#)
    lines.append(
      #"download_url=$(perl -0ne 'if (/"browser_download_url"\s*:\s*"([^"]+\.pkg)"/) { print "$1\n"; exit }' "$release_json")"#
    )
    lines.append(
      #"[ -n "$download_url" ] || { echo 'Apple Container latest release does not include a signed .pkg asset' >&2; exit 1; }"#
    )
    lines.append(#"pkg="$tmpdir/$(basename "$download_url")""#)
    lines.append(#"curl -fL "$download_url" -o "$pkg""#)
    lines.append("\(shellQuoted(Self.spctlPath)) --assess --type install \"$pkg\"")
    if options.openInstaller && !options.yes {
      lines.append(#"open "$pkg""#)
      lines.append(#"echo "Installer package left at: $pkg""#)
      lines.append(#"echo "Complete the macOS installer UI, then run: riela setup container --yes""#)
    } else {
      lines.append("sudo \(shellQuoted(Self.installerPath)) -pkg \"$pkg\" -target /")
      lines.append("\(shellQuoted(Self.defaultInstalledRuntimePath)) system start")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private func shellQuoted(_ value: String) -> String {
    if value.range(of: #"^[A-Za-z0-9_./:=@+-]+$"#, options: .regularExpression) != nil {
      return value
    }
    return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private func nextStep(runtimePath: String?, dryRun: Bool) -> String? {
    if runtimePath == nil {
      return "Install Apple Container from the signed package, then run riela setup container --yes."
    }
    if dryRun {
      return "Run riela setup container --yes to start the Apple Container system service."
    }
    return "Run riela doctor to verify container readiness."
  }

  private func render(_ result: SetupContainerResult, output: WorkflowOutputFormat) throws -> CLICommandResult {
    switch output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: .success, stdout: try jsonString(result))
    case .text, .table:
      return CLICommandResult(exitCode: .success, stdout: renderText(result))
    }
  }

  private func renderText(_ result: SetupContainerResult) -> String {
    if let script = result.script {
      return script
    }
    var lines = [
      "setup container: \(result.dryRun ? "dry-run" : "apply")",
      "release: \(result.releaseURL)"
    ]
    if let runtimePath = result.runtimePath {
      lines.append("runtime: \(runtimePath)")
    }
    lines.append("")
    lines.append("actions:")
    for action in result.actions {
      lines.append("- \(action.status.rawValue) \(action.description)")
      lines.append("  \(action.command.joined(separator: " "))")
    }
    if let nextStep = result.nextStep {
      lines.append("")
      lines.append("next: \(nextStep)")
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

private struct SetupContainerOptions: ParsableArguments, Sendable {
  @Flag(name: .shortAndLong) var yes = false
  @Flag var dryRun = false
  @Flag var printScript = false
  @Flag var openInstaller = false
  @Option var output: String?

  init() {}

  init(arguments: [String]) throws {
    do {
      self = try Self.parse(arguments)
    } catch {
      throw CLIUsageError(Self.message(for: error))
    }
  }

  mutating func validate() throws {
    if printScript {
      dryRun = true
    }
  }
}

public struct SetupContainerInstallerRelease: Equatable, Sendable {
  public var assetName: String
  public var downloadURL: URL

  public init(assetName: String, downloadURL: URL) {
    self.assetName = assetName
    self.downloadURL = downloadURL
  }
}

public protocol SetupContainerReleaseResolving: Sendable {
  func latestInstallerRelease() async throws -> SetupContainerInstallerRelease
}

public protocol SetupContainerDownloading: Sendable {
  func downloadInstaller(from url: URL) async throws -> URL
}

public struct GitHubSetupContainerReleaseResolver: SetupContainerReleaseResolving {
  public init() {}

  public func latestInstallerRelease() async throws -> SetupContainerInstallerRelease {
    guard let url = URL(string: SetupContainerCommand.releasesAPIURL) else {
      throw CLIUsageError("invalid Apple Container releases API URL")
    }
    let (data, response) = try await URLSession.shared.data(from: url)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw CLIUsageError("Apple Container release lookup failed with HTTP \(http.statusCode)")
    }
    let release = try JSONDecoder().decode(SetupContainerGitHubRelease.self, from: data)
    guard let asset = release.assets.first(where: { asset in
      asset.name.lowercased().hasSuffix(".pkg")
    }), let downloadURL = URL(string: asset.browserDownloadURL) else {
      throw CLIUsageError("Apple Container latest release does not include a signed .pkg asset")
    }
    return SetupContainerInstallerRelease(assetName: asset.name, downloadURL: downloadURL)
  }

}

private struct SetupContainerGitHubRelease: Decodable {
  var assets: [SetupContainerGitHubAsset]
}

private struct SetupContainerGitHubAsset: Decodable {
  var name: String
  var browserDownloadURL: String

  private enum CodingKeys: String, CodingKey {
    case name
    case browserDownloadURL = "browser_download_url"
  }
}

public struct URLSessionSetupContainerDownloader: SetupContainerDownloading {
  public init() {}

  public func downloadInstaller(from url: URL) async throws -> URL {
    let (temporaryURL, response) = try await URLSession.shared.download(from: url)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw CLIUsageError("Apple Container installer download failed with HTTP \(http.statusCode)")
    }
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-setup-container-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent(url.lastPathComponent.isEmpty ? "container.pkg" : url.lastPathComponent)
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: temporaryURL, to: destination)
    return destination
  }
}
