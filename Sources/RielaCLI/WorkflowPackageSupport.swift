import Foundation
import RielaAddons
import RielaCore

struct PackageSkillProjectionPlan {
  var vendor: WorkflowPackageSkillVendor
  var name: String
  var sourcePath: String
  var destination: URL
}

func packageSkillProjectionPlans(
  manifest: WorkflowPackageManifest,
  packageRoot: URL,
  scope: WorkflowScope,
  workingDirectory: URL
) throws -> [PackageSkillProjectionPlan] {
  var plans: [PackageSkillProjectionPlan] = []
  for skill in manifest.skills {
    if let plan = try packageSkillProjectionPlan(
      vendor: skill.vendor,
      name: skill.name,
      sourcePath: skill.sourcePath,
      packageRoot: packageRoot,
      scope: scope,
      workingDirectory: workingDirectory
    ) {
      plans.append(plan)
    }
  }
  if let skillDirectory = manifest.skillDirectory {
    plans.append(contentsOf: try discoverPackageSkillDirectoryProjections(
      skillDirectory: skillDirectory,
      packageRoot: packageRoot,
      scope: scope,
      workingDirectory: workingDirectory
    ))
  }
  var seen = Set<String>()
  return plans.filter { plan in
    let key = "\(plan.vendor.rawValue):\(plan.name):\(plan.destination.standardizedFileURL.path)"
    return seen.insert(key).inserted
  }
}

private func discoverPackageSkillDirectoryProjections(
  skillDirectory: String,
  packageRoot: URL,
  scope: WorkflowScope,
  workingDirectory: URL
) throws -> [PackageSkillProjectionPlan] {
  guard let normalized = WorkflowPackageManifestValidator.normalizePackageRelativePath(skillDirectory) else {
    throw CLIUsageError("skillDirectory: path must be package-relative")
  }
  let root = packageRoot.appendingPathComponent(normalized, isDirectory: true)
  guard FileManager.default.fileExists(atPath: root.path) else {
    return []
  }
  var plans: [PackageSkillProjectionPlan] = []
  let vendorDirectories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
  for vendorDirectory in vendorDirectories where (try? vendorDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
    guard let vendor = WorkflowPackageSkillVendor(rawValue: vendorDirectory.lastPathComponent) else {
      continue
    }
    switch vendor {
    case .codex, .claude:
      let skillDirectories = try FileManager.default.contentsOfDirectory(at: vendorDirectory, includingPropertiesForKeys: [.isDirectoryKey])
      for skillDirectory in skillDirectories where (try? skillDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        let skillName = skillDirectory.lastPathComponent
        guard FileManager.default.fileExists(atPath: skillDirectory.appendingPathComponent("SKILL.md").path) else {
          continue
        }
        if let plan = try packageSkillProjectionPlan(
          vendor: vendor,
          name: skillName,
          sourcePath: packageRelativePath(for: skillDirectory, packageRoot: packageRoot),
          packageRoot: packageRoot,
          scope: scope,
          workingDirectory: workingDirectory
        ) {
          plans.append(plan)
        }
      }
    case .cursor:
      let cursorFiles = try FileManager.default.contentsOfDirectory(at: vendorDirectory, includingPropertiesForKeys: [.isRegularFileKey])
      for cursorFile in cursorFiles where cursorFile.pathExtension == "mdc" {
        let skillName = cursorFile.deletingPathExtension().lastPathComponent
        if let plan = try packageSkillProjectionPlan(
          vendor: vendor,
          name: skillName,
          sourcePath: packageRelativePath(for: cursorFile, packageRoot: packageRoot),
          packageRoot: packageRoot,
          scope: scope,
          workingDirectory: workingDirectory
        ) {
          plans.append(plan)
        }
      }
    case .agents:
      let agentsFile = vendorDirectory.appendingPathComponent("AGENTS.md")
      if FileManager.default.fileExists(atPath: agentsFile.path),
        let plan = try packageSkillProjectionPlan(
          vendor: vendor,
          name: "agents",
          sourcePath: packageRelativePath(for: agentsFile, packageRoot: packageRoot),
          packageRoot: packageRoot,
          scope: scope,
          workingDirectory: workingDirectory
        ) {
        plans.append(plan)
      }
    case .gemini:
      let geminiFile = vendorDirectory.appendingPathComponent("GEMINI.md")
      if FileManager.default.fileExists(atPath: geminiFile.path),
        let plan = try packageSkillProjectionPlan(
          vendor: vendor,
          name: "gemini",
          sourcePath: packageRelativePath(for: geminiFile, packageRoot: packageRoot),
          packageRoot: packageRoot,
          scope: scope,
          workingDirectory: workingDirectory
        ) {
        plans.append(plan)
      }
    }
  }
  return plans
}

private func packageSkillProjectionPlan(
  vendor: WorkflowPackageSkillVendor,
  name: String,
  sourcePath: String,
  packageRoot: URL,
  scope: WorkflowScope,
  workingDirectory: URL
) throws -> PackageSkillProjectionPlan? {
  guard isSafeSkillProjectionName(name) else {
    throw CLIUsageError("invalid skill name '\(name)'")
  }
  guard let normalized = WorkflowPackageManifestValidator.normalizePackageRelativePath(sourcePath) else {
    throw CLIUsageError("skills.\(name).sourcePath: path must be package-relative")
  }
  let source = packageRoot.appendingPathComponent(normalized)
  let sourceIsDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  let sourceRoot: URL
  switch vendor {
  case .codex, .claude:
    sourceRoot = source.lastPathComponent == "SKILL.md" ? source.deletingLastPathComponent() : source
    guard FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent("SKILL.md").path) else {
      throw CLIUsageError("skill source must contain SKILL.md: \(sourceRoot.path)")
    }
  case .cursor:
    sourceRoot = sourceIsDirectory ? source.appendingPathComponent("\(name).mdc") : source
    guard sourceRoot.pathExtension == "mdc", FileManager.default.fileExists(atPath: sourceRoot.path) else {
      throw CLIUsageError("cursor skill source must be a .mdc file: \(sourceRoot.path)")
    }
  case .agents:
    sourceRoot = sourceIsDirectory ? source.appendingPathComponent("AGENTS.md") : source
    guard sourceRoot.lastPathComponent == "AGENTS.md", FileManager.default.fileExists(atPath: sourceRoot.path) else {
      throw CLIUsageError("agents skill source must be AGENTS.md: \(sourceRoot.path)")
    }
  case .gemini:
    sourceRoot = sourceIsDirectory ? source.appendingPathComponent("GEMINI.md") : source
    guard sourceRoot.lastPathComponent == "GEMINI.md", FileManager.default.fileExists(atPath: sourceRoot.path) else {
      throw CLIUsageError("gemini skill source must be GEMINI.md: \(sourceRoot.path)")
    }
  }
  guard let destination = packageSkillProjectionDestination(vendor: vendor, name: name, scope: scope, workingDirectory: workingDirectory) else {
    return nil
  }
  return PackageSkillProjectionPlan(
    vendor: vendor,
    name: name,
    sourcePath: packageRelativePath(for: sourceRoot, packageRoot: packageRoot),
    destination: destination
  )
}

private func packageSkillProjectionDestination(
  vendor: WorkflowPackageSkillVendor,
  name: String,
  scope: WorkflowScope,
  workingDirectory: URL
) -> URL? {
  let home = URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(), isDirectory: true)
  switch vendor {
  case .codex:
    let codexHome = CLIRuntimeEnvironment.mergedProcessEnvironment()["CODEX_HOME"]
      .flatMap { $0.isEmpty ? nil : $0 }
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? home.appendingPathComponent(".codex", isDirectory: true)
    let root = scope == .user ? codexHome : workingDirectory.appendingPathComponent(".codex", isDirectory: true)
    return root.appendingPathComponent("skills", isDirectory: true).appendingPathComponent(name, isDirectory: true)
  case .claude:
    let root = scope == .user ? home.appendingPathComponent(".claude", isDirectory: true) : workingDirectory.appendingPathComponent(".claude", isDirectory: true)
    return root.appendingPathComponent("skills", isDirectory: true).appendingPathComponent(name, isDirectory: true)
  case .cursor:
    guard scope != .user else {
      return nil
    }
    return workingDirectory
      .appendingPathComponent(".cursor", isDirectory: true)
      .appendingPathComponent("rules", isDirectory: true)
      .appendingPathComponent("\(name).mdc", isDirectory: false)
  case .agents:
    guard scope != .user else {
      return nil
    }
    return workingDirectory.appendingPathComponent("AGENTS.md", isDirectory: false)
  case .gemini:
    guard scope != .user else {
      return nil
    }
    return workingDirectory.appendingPathComponent("GEMINI.md", isDirectory: false)
  }
}

func preflightSkillProjections(_ projections: [PackageSkillProjectionPlan], overwrite: Bool) throws {
  for projection in projections where FileManager.default.fileExists(atPath: projection.destination.path) {
    guard overwrite else {
      throw CLIUsageError("skill projection already exists: \(projection.destination.path); pass --overwrite to replace it")
    }
  }
}

func installSkillProjections(
  _ projections: [PackageSkillProjectionPlan],
  installedPackageRoot: URL,
  overwrite: Bool,
  recordCreated: (URL) -> Void = { _ in }
) throws {
  for projection in projections {
    let source = installedPackageRoot.appendingPathComponent(projection.sourcePath)
    guard FileManager.default.fileExists(atPath: source.path) else {
      throw CLIUsageError("installed skill source missing: \(source.path)")
    }
    let destinationExisted = FileManager.default.fileExists(atPath: projection.destination.path)
    if FileManager.default.fileExists(atPath: projection.destination.path) {
      guard overwrite else {
        throw CLIUsageError("skill projection already exists: \(projection.destination.path); pass --overwrite to replace it")
      }
      try FileManager.default.removeItem(at: projection.destination)
    }
    try FileManager.default.createDirectory(at: projection.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source, to: projection.destination)
    if !destinationExisted {
      recordCreated(projection.destination)
    }
  }
}

func packageRelativePath(for url: URL, packageRoot: URL) -> String {
  let rootPath = packageRoot.standardizedFileURL.path
  let urlPath = url.standardizedFileURL.path
  if urlPath == rootPath {
    return "."
  }
  return String(urlPath.dropFirst(rootPath.hasSuffix("/") ? rootPath.count : rootPath.count + 1))
}

private func isSafeSkillProjectionName(_ name: String) -> Bool {
  guard let first = name.unicodeScalars.first, isParityASCIIAlphaNumeric(first), name.unicodeScalars.count <= 80 else {
    return false
  }
  return name.unicodeScalars.allSatisfy { scalar in
    isParityASCIIAlphaNumeric(scalar) || scalar == "." || scalar == "_" || scalar == "-"
  }
}

func packageRoot(scope: WorkflowScope, workingDirectory: URL) -> URL {
  switch scope {
  case .user:
    return URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory()).appendingPathComponent(".riela/packages", isDirectory: true)
  case .auto, .project, .direct:
    return workingDirectory.appendingPathComponent(".riela/packages", isDirectory: true)
  }
}

func packageRoots(parsed: ParsedParityOptions, workingDirectory: URL) -> [URL] {
  switch parsed.scope {
  case .user:
    return [packageRoot(scope: .user, workingDirectory: workingDirectory)]
  case .project:
    return [packageRoot(scope: .project, workingDirectory: workingDirectory)]
  case .auto, .direct:
    return [packageRoot(scope: .project, workingDirectory: workingDirectory), packageRoot(scope: .user, workingDirectory: workingDirectory)]
  }
}

func packageManifestURLs(in root: URL) throws -> [URL] {
  let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
  var manifests: [URL] = []
  for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
    let directManifest = entry.appendingPathComponent("riela-package.json")
    if FileManager.default.fileExists(atPath: directManifest.path) {
      manifests.append(directManifest)
      continue
    }
    guard entry.lastPathComponent.hasPrefix("@") else {
      continue
    }
    let scopedEntries = try FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.isDirectoryKey])
    for scopedEntry in scopedEntries where (try? scopedEntry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      let scopedManifest = scopedEntry.appendingPathComponent("riela-package.json")
      if FileManager.default.fileExists(atPath: scopedManifest.path) {
        manifests.append(scopedManifest)
      }
    }
  }
  return manifests.sorted { $0.path < $1.path }
}

func workflowPackageSummary(
  manifest: WorkflowPackageManifest,
  packageDirectory: URL,
  valid: Bool,
  issues: [WorkflowPackageValidationIssue]
) -> WorkflowPackageSummary {
  WorkflowPackageSummary(
    name: manifest.name,
    version: manifest.version,
    kind: manifest.kind,
    title: manifest.title ?? manifest.workflow?.title,
    description: manifest.description ?? manifest.workflow?.description,
    tags: manifest.tags,
    backends: packageSummaryBackends(manifest),
    workflowIds: packageSummaryWorkflowIds(manifest: manifest, packageDirectory: packageDirectory),
    addons: packageSummaryAddons(manifest),
    requiredEnvironment: manifest.environmentVariables.filter(\.required),
    packageDirectory: packageDirectory.path,
    workflowDirectory: manifest.workflowDirectory,
    valid: valid,
    issues: issues
  )
}

private func packageSummaryAddons(_ manifest: WorkflowPackageManifest) -> [WorkflowPackageAddonSummary]? {
  guard !manifest.nodeAddons.isEmpty else {
    return nil
  }
  return manifest.nodeAddons.map { addon in
    WorkflowPackageAddonSummary(
      name: addon.name,
      version: addon.version,
      sourcePath: addon.sourcePath,
      executionKind: addon.execution?.kind,
      contentDigest: addon.contentDigest
    )
  }
}

private func packageSummaryBackends(_ manifest: WorkflowPackageManifest) -> [String] {
  var seen = Set<String>()
  let values = manifest.backends + (manifest.workflow?.backends ?? []) + manifest.workflows.flatMap(\.backends)
  return values.filter { seen.insert($0.lowercased()).inserted }
}

private func packageSummaryWorkflowIds(manifest: WorkflowPackageManifest, packageDirectory: URL) -> [String] {
  let workflowDirectories = [manifest.workflowDirectory].compactMap { $0 }.filter { !$0.isEmpty }
  guard !workflowDirectories.isEmpty else {
    return [packageDirectory.lastPathComponent]
  }
  var seen = Set<String>()
  return workflowDirectories.map { path in
    path == "." ? packageDirectory.lastPathComponent : URL(fileURLWithPath: path).lastPathComponent
  }.filter { seen.insert($0).inserted }
}

func packageFilesystemKey(_ packageName: String) -> String {
  packageName.unicodeScalars.map { scalar in
    if isParityASCIIAlphaNumeric(scalar) || scalar == "." || scalar == "-" || scalar == "_" {
      return String(Character(scalar))
    }
    let hex = String(scalar.value, radix: 16, uppercase: true)
    return "%" + String(repeating: "0", count: max(0, 2 - hex.count)) + hex
  }.joined()
}

func registryConfigURL(parsed: ParsedParityOptions) -> URL {
  let workingDirectory = URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath, isDirectory: true)
  return workingDirectory
    .appendingPathComponent(".riela/workflow-packages", isDirectory: true)
    .appendingPathComponent("registries.json")
}

func isSafeRegistryId(_ id: String) -> Bool {
  guard let first = id.unicodeScalars.first, isParityASCIIAlphaNumeric(first), id.unicodeScalars.count <= 80 else {
    return false
  }
  return id.unicodeScalars.allSatisfy { scalar in
    isParityASCIIAlphaNumeric(scalar) || scalar == "." || scalar == "_" || scalar == "-"
  }
}

func isSupportedRegistryURL(_ value: String) -> Bool {
  guard let url = URL(string: value), url.scheme == "https", url.host == "github.com" else {
    return false
  }
  let components = url.pathComponents.filter { $0 != "/" }
  return components.count == 2
}

func directRegistryId(for registryURL: String) -> String {
  guard let url = URL(string: registryURL) else {
    return "github-registry"
  }
  let components = url.pathComponents.filter { $0 != "/" }
  let owner = components.first ?? "unknown"
  let repo = components.dropFirst().first ?? "registry"
  let raw = "github-\(owner)-\(repo)"
  return String(raw.unicodeScalars.map { scalar in
    isParityASCIIAlphaNumeric(scalar) || scalar == "." || scalar == "_" || scalar == "-"
      ? Character(scalar)
      : "-"
  })
}

func renderRegistryConfig(
  _ config: WorkflowPackageRegistryConfig,
  output: WorkflowOutputFormat,
  text: String? = nil
) throws -> CLICommandResult {
  switch output {
  case .json, .jsonl:
    return CLICommandResult(exitCode: .success, stdout: try jsonString(config))
  case .text, .table:
    if let text {
      return CLICommandResult(exitCode: .success, stdout: text)
    }
    return CLICommandResult(
      exitCode: .success,
      stdout: config.registries.map { registry in
        [
          registry.id,
          registry.url,
          registry.defaultBranch,
          registry.localPath ?? ""
        ].joined(separator: "\t")
      }.joined(separator: "\n") + (config.registries.isEmpty ? "" : "\n")
    )
  }
}

func renderPackage(_ result: WorkflowPackageCommandResult, output: WorkflowOutputFormat) throws -> CLICommandResult {
  switch output {
  case .json, .jsonl:
    return CLICommandResult(exitCode: .success, stdout: try jsonString(result))
  case .text:
    return CLICommandResult(exitCode: .success, stdout: humanReadablePackageResult(result))
  case .table:
    if result.command == PackageCommandKind.search.rawValue {
      let rows = result.packages.map {
        [
          $0.name,
          ($0.workflowIds ?? []).joined(separator: ",").nilIfEmpty ?? "-",
          packageRegistryLabel($0),
          $0.tags.isEmpty ? "-" : $0.tags.joined(separator: ","),
          $0.description ?? $0.title ?? "-"
        ].joined(separator: "\t")
      }
      return CLICommandResult(
        exitCode: .success,
        stdout: (["PACKAGE\tWORKFLOW\tREGISTRY\tTAGS\tSUMMARY"] + rows).joined(separator: "\n") + "\n"
      )
    }
    let rows = result.packages.map {
      [
        $0.name,
        $0.version ?? "-",
        $0.kind.rawValue,
        $0.tags.isEmpty ? "-" : $0.tags.joined(separator: ","),
        $0.valid ? "valid" : "invalid"
      ].joined(separator: "\t")
    }
    return CLICommandResult(exitCode: .success, stdout: (["PACKAGE\tVERSION\tKIND\tTAGS\tSTATUS"] + rows).joined(separator: "\n") + "\n")
  }
}

func packageMessageWithContainerSetupHint(
  _ message: String,
  packages: [WorkflowPackageSummary],
  environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
) -> String {
  guard packageNeedsContainerSetupHint(packages: packages, environment: environment) else {
    return message
  }
  return message + "; container runtime missing for container add-ons, run `riela setup container --yes` or set RIELA_CONTAINER_RUNTIME"
}

private func packageNeedsContainerSetupHint(
  packages: [WorkflowPackageSummary],
  environment: [String: String]
) -> Bool {
  let hasContainerAddon = packages.contains { package in
    package.addons?.contains { addon in
      addon.executionKind == .container
    } == true
  }
  guard hasContainerAddon else {
    return false
  }
  let discovery = ContainerRuntimeDiscovery(environment: environment)
  return discovery.configuredDriver() == nil && discovery.selectedAvailableDriver() == nil
}

private func humanReadablePackageResult(_ result: WorkflowPackageCommandResult) -> String {
  var lines = [result.message]
  let commandPrefix = result.scope == "workflow package" ? "riela workflow package" : "riela package"
  for package in result.packages {
    lines.append("Package: \(package.name) \(package.version ?? "-") (\(package.kind.rawValue), \(package.valid ? "valid" : "invalid"))")
    if !package.tags.isEmpty {
      lines.append("Tags: \(package.tags.joined(separator: ", "))")
    }
    if let workflowDirectory = package.workflowDirectory {
      lines.append("Workflow: \(workflowDirectory)")
    }
    if let addons = package.addons, !addons.isEmpty {
      lines.append("Add-ons: \(addons.map { "\($0.name)@\($0.version)" }.joined(separator: ", "))")
    }
    if let requiredEnvironment = package.requiredEnvironment, !requiredEnvironment.isEmpty {
      lines.append("Environment:")
      for requirement in requiredEnvironment {
        let secret = requirement.secret ? " secret" : ""
        let description = requirement.description.map { " - \($0)" } ?? ""
        lines.append("  - \(requirement.name)\(secret)\(description)")
      }
    }
    if result.command == PackageCommandKind.validate.rawValue,
      let input = result.destinationDirectory ?? result.target {
      lines.append("Input: \(input)")
    } else if result.command != PackageCommandKind.install.rawValue,
      result.command != PackageCommandKind.ci.rawValue,
      result.command != PackageCommandKind.checkout.rawValue {
      lines.append("Source: \(package.packageDirectory)")
    }
    if !package.issues.isEmpty {
      lines.append("Issues:")
      lines.append(contentsOf: package.issues.map { "  - \($0.path): \($0.message)" })
    }
  }
  if let destination = result.destinationDirectory, result.command != PackageCommandKind.validate.rawValue {
    lines.append(destinationLabel(for: result.command) + ": \(destination)")
  }
  if let runSessionId = result.runSessionId {
    lines.append("Run session: \(runSessionId)")
  }
  if let nextStep = packageNextStep(result, commandPrefix: commandPrefix) {
    lines.append("Next: \(nextStep)")
  }
  if let appStep = packageRielaAppStep(result) {
    lines.append("RielaApp: \(appStep)")
  }
  return lines.joined(separator: "\n") + "\n"
}

private func packageRegistryLabel(_ package: WorkflowPackageSummary) -> String {
  let path = URL(fileURLWithPath: package.packageDirectory).standardizedFileURL.path
  guard let markerRange = path.range(of: "/packages/") else {
    return "-"
  }
  let prefix = String(path[..<markerRange.lowerBound])
  return URL(fileURLWithPath: prefix).lastPathComponent.nilIfEmpty ?? "-"
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}

private func destinationLabel(for command: String) -> String {
  switch command {
  case PackageCommandKind.initialize.rawValue:
    return "Manifest"
  case PackageCommandKind.pack.rawValue:
    return "Archive"
  case PackageCommandKind.install.rawValue:
    return "Installed"
  case PackageCommandKind.ci.rawValue:
    return "Lockfile"
  case PackageCommandKind.publish.rawValue:
    return "Registry record"
  default:
    return "Path"
  }
}

private func packageNextStep(_ result: WorkflowPackageCommandResult, commandPrefix: String) -> String? {
  switch result.command {
  case PackageCommandKind.initialize.rawValue:
    guard let source = result.packages.first?.packageDirectory else {
      return nil
    }
    return "\(commandPrefix) pack \(shellArgument(source))"
  case PackageCommandKind.pack.rawValue:
    guard let archive = result.destinationDirectory else {
      return nil
    }
    return "\(commandPrefix) validate \(shellArgument(archive))"
  case PackageCommandKind.validate.rawValue:
    return nil
  case PackageCommandKind.install.rawValue:
    guard let packageName = result.packages.first?.name,
      let destination = result.destinationDirectory else {
      return nil
    }
    return workflowRunNextStep(packageName: packageName, installedPackageDirectory: destination)
  default:
    return nil
  }
}

private func workflowRunNextStep(packageName: String, installedPackageDirectory: String) -> String {
  let destination = URL(fileURLWithPath: installedPackageDirectory, isDirectory: true).standardizedFileURL
  let packageRoot = destination.deletingLastPathComponent()
  let rielaRoot = packageRoot.deletingLastPathComponent()
  guard packageRoot.lastPathComponent == "packages", rielaRoot.lastPathComponent == ".riela" else {
    return "riela workflow run \(packageName) --scope project"
  }
  let userPackageRoot = URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(), isDirectory: true)
    .appendingPathComponent(".riela/packages", isDirectory: true)
    .standardizedFileURL
  if packageRoot.path == userPackageRoot.path {
    return "riela workflow run \(packageName) --scope user"
  }
  let projectRoot = rielaRoot.deletingLastPathComponent()
  return "riela workflow run \(packageName) --scope project --working-dir \(shellArgument(projectRoot.path))"
}

private func packageRielaAppStep(_ result: WorkflowPackageCommandResult) -> String? {
  if result.command == PackageCommandKind.pack.rawValue, let archive = result.destinationDirectory {
    return appImportStep(source: archive)
  }
  if result.command == PackageCommandKind.validate.rawValue,
    let source = result.destinationDirectory ?? result.target,
    result.packages.first?.valid == true {
    return appImportStep(source: source)
  }
  guard result.command == PackageCommandKind.install.rawValue,
    let destination = result.destinationDirectory else {
    return nil
  }
  let destinationURL = URL(fileURLWithPath: destination, isDirectory: true).standardizedFileURL
  let packageRoot = destinationURL.deletingLastPathComponent()
  let rielaRoot = packageRoot.deletingLastPathComponent()
  guard packageRoot.lastPathComponent == "packages", rielaRoot.lastPathComponent == ".riela" else {
    return nil
  }
  let userPackageRoot = URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(), isDirectory: true)
    .appendingPathComponent(".riela/packages", isDirectory: true)
    .standardizedFileURL
  if packageRoot.path == userPackageRoot.path {
    return "Workflows... > Refresh to show the user package in every profile, or Add Workflow/Package... and choose \(destination)"
  }
  return "Add Project... and choose \(rielaRoot.deletingLastPathComponent().path)"
}

private func appImportStep(source: String) -> String {
  "Add Workflow/Package... and choose \(source), or launch RielaApp with --import-workflow-or-package \(shellArgument(source)) --open-workflows"
}

private func shellArgument(_ value: String) -> String {
  guard !value.isEmpty else {
    return "''"
  }
  let safeScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-=.,/:@%")
  if value.unicodeScalars.allSatisfy({ safeScalars.contains($0) }) {
    return value
  }
  return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
