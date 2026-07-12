import Foundation

/// Pre-install check policy. `off` (default) skips scanning; `warn` reports and
/// proceeds; `reject` blocks install on high/critical findings.
public enum WorkflowPackagePreInstallMode: String, Codable, Sendable {
  case off
  case warn
  case reject
}

/// Requested container runtime for the optional no-network container check.
public enum WorkflowPackageContainerRuntimeRequest: String, Codable, Sendable {
  case off
  case docker
  case podman
  case auto
}

public enum WorkflowPackagePreInstallSeverity: String, Codable, Sendable, Comparable {
  case low
  case medium
  case high
  case critical

  private var rank: Int {
    switch self {
    case .low: return 0
    case .medium: return 1
    case .high: return 2
    case .critical: return 3
    }
  }

  var isBlocking: Bool {
    self >= .high
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rank < rhs.rank
  }
}

/// A single static-scanner finding. `excerpt` is always redacted — it never
/// contains a full secret value.
public struct WorkflowPackagePreInstallFinding: Codable, Equatable, Sendable {
  var ruleName: String
  var severity: WorkflowPackagePreInstallSeverity
  var path: String
  var excerpt: String
  var remediation: String
}

/// Result surface for a pre-install check, attached to install results only
/// when a check was requested.
public struct WorkflowPackagePreInstallCheckResult: Codable, Equatable, Sendable {
  var mode: WorkflowPackagePreInstallMode
  var success: Bool
  var findings: [WorkflowPackagePreInstallFinding]
  var containerRuntime: String?
  var containerDiagnostic: String?
}

/// Error thrown by a `reject`-mode check when blocking findings are present.
/// Thrown before any destination or lock write so install rolls back cleanly.
struct WorkflowPackagePreInstallRejection: Error, CustomStringConvertible {
  var result: WorkflowPackagePreInstallCheckResult

  var description: String {
    let blocking = result.findings.filter { $0.severity.isBlocking }
    let summary = blocking.map { "\($0.severity.rawValue) \($0.ruleName) (\($0.path))" }.joined(separator: "; ")
    return "pre-install check rejected package: \(summary)"
  }
}

/// Static content scanner. Reads staged package files WITHOUT executing any
/// content and reports risky patterns in packaged workflows and skills.
struct WorkflowPackagePreInstallScanner: Sendable {
  private struct Rule {
    var name: String
    var severity: WorkflowPackagePreInstallSeverity
    var remediation: String
    var matches: @Sendable (String) -> Range<String.Index>?
  }

  /// Maximum bytes read per file. Keeps scanning bounded for large payloads.
  private let maxFileBytes = 512 * 1024

  private static let promptOverridePattern =
    #"(?i)(ignore\s+(all\s+|any\s+|the\s+|your\s+)*"#
    + #"(previous\s+|prior\s+|earlier\s+|above\s+)*(instructions|prompts|directions)"#
    + #"|disregard\s+(the\s+|all\s+)*(system|previous|prior)\s+(prompt|instructions))"#

  private let scannableExtensions: Set<String> = [
    "json", "md", "txt", "sh", "bash", "zsh", "py", "js", "ts", "rb",
    "yaml", "yml", "toml", "prompt", "tmpl", "template", ""
  ]

  func scan(packageDirectory: URL) throws -> [WorkflowPackagePreInstallFinding] {
    let files = try scannableFiles(in: packageDirectory)
    var findings: [WorkflowPackagePreInstallFinding] = []
    for file in files {
      let relativePath = self.relativePath(for: file, root: packageDirectory)
      guard let contents = readContents(of: file) else {
        continue
      }
      for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
        let text = String(line)
        for rule in rules {
          guard let range = rule.matches(text) else {
            continue
          }
          findings.append(WorkflowPackagePreInstallFinding(
            ruleName: rule.name,
            severity: rule.severity,
            path: relativePath,
            excerpt: redactedExcerpt(text, matchRange: range),
            remediation: rule.remediation
          ))
        }
      }
    }
    return findings.sorted { lhs, rhs in
      if lhs.severity != rhs.severity {
        return lhs.severity > rhs.severity
      }
      if lhs.path != rhs.path {
        return lhs.path < rhs.path
      }
      return lhs.ruleName < rhs.ruleName
    }
  }

  private var rules: [Rule] {
    [
      Rule(
        name: "curl-pipe-shell",
        severity: .critical,
        remediation: "Remove piped remote-script execution; vendor scripts into the package and review them."
      ) { line in
        firstRange(in: line, pattern: #"(?i)(curl|wget)\b[^\n|]*\|\s*(sudo\s+)?(sh|bash|zsh)\b"#)
      },
      Rule(
        name: "base64-decode-pipe-shell",
        severity: .critical,
        remediation: "Remove obfuscated decode-then-execute chains; use plain reviewable scripts."
      ) { line in
        firstRange(in: line, pattern: #"(?i)base64\s+(--?d(ecode)?)\b[^\n|]*\|\s*(sh|bash|zsh)\b"#)
      },
      Rule(
        name: "shell-eval-command-substitution",
        severity: .high,
        remediation: "Avoid eval and command substitution in packaged content; use explicit commands."
      ) { line in
        firstRange(in: line, pattern: #"(?i)\beval\s+\$?\(|\$\((curl|wget|eval)\b"#)
      },
      Rule(
        name: "credential-material",
        severity: .high,
        remediation: "Remove embedded secrets; require them as documented environment variables instead."
      ) { line in
        firstRange(in: line, pattern: #"(?i)(aws_secret_access_key|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[baprs]-[0-9A-Za-z-]{10,}|gh[pousr]_[0-9A-Za-z]{20,}|AKIA[0-9A-Z]{16})"#)
      },
      Rule(
        name: "network-exfiltration",
        severity: .high,
        remediation: "Remove instructions that transmit local files or environment to remote hosts."
      ) { line in
        firstRange(in: line, pattern: #"(?i)(curl|wget)\b[^\n]*(-d|--data|-F|--form|-T|--upload-file)\b[^\n]*(https?://|\$\{?[A-Z_]*(TOKEN|SECRET|KEY|ENV))"#)
      },
      Rule(
        name: "prompt-instruction-override",
        severity: .medium,
        remediation: "Review prompt-injection-style overrides that could redirect the agent."
      ) { line in
        firstRange(in: line, pattern: Self.promptOverridePattern)
      },
      Rule(
        name: "absolute-machine-local-path",
        severity: .low,
        remediation: "Replace machine-local absolute paths with package-relative references."
      ) { line in
        firstRange(in: line, pattern: #"(/Users/|/home/)[A-Za-z0-9._-]+/"#)
      }
    ]
  }

  private func scannableFiles(in root: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }
    var files: [URL] = []
    for case let fileURL as URL in enumerator {
      let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else {
        continue
      }
      let ext = fileURL.pathExtension.lowercased()
      guard scannableExtensions.contains(ext) else {
        continue
      }
      files.append(fileURL.standardizedFileURL)
    }
    return files.sorted { $0.path < $1.path }
  }

  private func readContents(of file: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: file) else {
      return nil
    }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: maxFileBytes)) ?? Data()
    return String(data: data, encoding: .utf8)
  }

  private func relativePath(for url: URL, root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let urlPath = url.standardizedFileURL.path
    guard urlPath.hasPrefix(rootPath) else {
      return url.lastPathComponent
    }
    let dropped = urlPath.dropFirst(rootPath.hasSuffix("/") ? rootPath.count : rootPath.count + 1)
    return String(dropped)
  }

  /// Produce a short excerpt around the match with the matched region masked so
  /// full secret values never leak into findings or logs.
  private func redactedExcerpt(_ line: String, matchRange: Range<String.Index>) -> String {
    let collapsed = line.trimmingCharacters(in: .whitespaces)
    guard let range = collapsed.range(of: String(line[matchRange])) else {
      return String(collapsed.prefix(80))
    }
    let masked = collapsed.replacingCharacters(in: range, with: "[REDACTED]")
    return String(masked.prefix(160))
  }
}

private func firstRange(in text: String, pattern: String) -> Range<String.Index>? {
  guard let regex = try? NSRegularExpression(pattern: pattern) else {
    return nil
  }
  let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
  guard let match = regex.firstMatch(in: text, range: nsRange),
    let range = Range(match.range, in: text) else {
    return nil
  }
  return range
}

/// Builds no-network container command argv for the optional container check.
/// Pure command builder: no execution here, so it is unit-testable without a
/// runtime installed.
struct WorkflowPackageContainerCommandBuilder: Sendable {
  /// Environment variable names whose values must never be forwarded.
  static func isSecretEnvName(_ name: String) -> Bool {
    let upper = name.uppercased()
    let markers = ["TOKEN", "SECRET", "KEY", "PASSWORD", "PASSWD", "CREDENTIAL", "SESSION", "COOKIE", "AUTH"]
    return markers.contains { upper.contains($0) }
  }

  /// Filter out secret-like environment variables before any container run.
  static func filteredEnvironment(_ environment: [String: String]) -> [String: String] {
    environment.filter { !isSecretEnvName($0.key) }
  }

  /// Construct the argv for a locked-down no-network inspection container.
  func command(
    runtime: String,
    packageDirectory: URL,
    image: String = "docker.io/library/alpine:3.20",
    environment: [String: String] = [:]
  ) -> [String] {
    var argv = [
      runtime, "run", "--rm",
      "--network", "none",
      "--read-only",
      "--security-opt", "no-new-privileges",
      "--cap-drop", "ALL",
      "--mount",
      "type=bind,source=\(packageDirectory.standardizedFileURL.path),target=/package,readonly",
      "--workdir", "/package"
    ]
    for (name, value) in Self.filteredEnvironment(environment).sorted(by: { $0.key < $1.key }) {
      argv.append(contentsOf: ["--env", "\(name)=\(value)"])
    }
    argv.append(image)
    argv.append(contentsOf: ["/bin/sh", "-c", "ls -R /package >/dev/null 2>&1 || true"])
    return argv
  }

  /// Resolve the `auto` request to docker first, then podman, using the given
  /// availability probe. Returns nil when neither is available.
  func resolveRuntime(
    _ request: WorkflowPackageContainerRuntimeRequest,
    isAvailable: (String) -> Bool
  ) -> String? {
    switch request {
    case .off:
      return nil
    case .docker:
      return isAvailable("docker") ? "docker" : nil
    case .podman:
      return isAvailable("podman") ? "podman" : nil
    case .auto:
      if isAvailable("docker") {
        return "docker"
      }
      if isAvailable("podman") {
        return "podman"
      }
      return nil
    }
  }
}

/// Runs the requested pre-install checks over a staged package.
struct WorkflowPackagePreInstallChecker: Sendable {
  var scanner = WorkflowPackagePreInstallScanner()
  var containerBuilder = WorkflowPackageContainerCommandBuilder()
  var runtimeIsAvailable: @Sendable (String) -> Bool = { runtime in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["which", runtime]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }

  /// Run the static scan (always) plus optional container availability probe.
  /// In `reject` mode, throws `WorkflowPackagePreInstallRejection` on blocking
  /// findings so the caller aborts before any destination write.
  func check(
    packageDirectory: URL,
    mode: WorkflowPackagePreInstallMode,
    container: WorkflowPackageContainerRuntimeRequest
  ) throws -> WorkflowPackagePreInstallCheckResult {
    let findings = try scanner.scan(packageDirectory: packageDirectory)
    var containerRuntime: String?
    var containerDiagnostic: String?
    if container != .off {
      if let runtime = containerBuilder.resolveRuntime(container, isAvailable: runtimeIsAvailable) {
        containerRuntime = runtime
      } else {
        containerDiagnostic = "no container runtime available for \(container.rawValue); static scan only"
      }
    }
    let hasBlocking = findings.contains { $0.severity.isBlocking }
    let success = mode == .reject ? !hasBlocking : true
    let result = WorkflowPackagePreInstallCheckResult(
      mode: mode,
      success: success,
      findings: findings,
      containerRuntime: containerRuntime,
      containerDiagnostic: containerDiagnostic
    )
    if mode == .reject && hasBlocking {
      throw WorkflowPackagePreInstallRejection(result: result)
    }
    return result
  }
}
