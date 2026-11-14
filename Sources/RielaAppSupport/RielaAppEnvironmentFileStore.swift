#if os(macOS)
import Foundation
import RielaAddons

public struct RielaAppEnvironmentVariableStatus: Equatable, Sendable {
  public var name: String
  public var configured: Bool

  public init(name: String, configured: Bool) {
    self.name = name
    self.configured = configured
  }
}

public struct RielaAppEnvironmentFileStore: Sendable {
  public var environmentFileURL: URL?
  public var processEnvironment: [String: String]

  public init(
    environmentFileURL: URL? = nil,
    processEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.environmentFileURL = environmentFileURL
    self.processEnvironment = processEnvironment
  }

  public func mergedEnvironment() -> [String: String] {
    var environment = processEnvironment
    if let environmentFileURL {
      environment.merge(Self.parseEnvironmentFile(environmentFileURL)) { _, fileValue in fileValue }
    }
    return environment
  }

  public func statuses(for names: [String]) -> [RielaAppEnvironmentVariableStatus] {
    let environment = mergedEnvironment()
    return names.map { name in
      let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
      return RielaAppEnvironmentVariableStatus(name: name, configured: value?.isEmpty == false)
    }
  }

  public static func parseEnvironmentFile(_ url: URL) -> [String: String] {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
      return [:]
    }
    var values: [String: String] = [:]
    for rawLine in contents.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("#") else {
        continue
      }
      let assignment = line.hasPrefix("export ")
        ? String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
        : line
      guard let separator = assignment.firstIndex(of: "=") else {
        continue
      }
      let key = assignment[..<separator].trimmingCharacters(in: .whitespaces)
      guard WorkflowPackageManifestValidator.isValidEnvironmentVariableName(String(key)) else {
        continue
      }
      let value = assignment[assignment.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      values[String(key)] = unquotedEnvironmentValue(String(value))
    }
    return values
  }

  private static func unquotedEnvironmentValue(_ value: String) -> String {
    guard value.count >= 2,
      let first = value.first,
      let last = value.last,
      (first == "\"" && last == "\"") || (first == "'" && last == "'")
    else {
      return value
    }
    return String(value.dropFirst().dropLast())
      .replacingOccurrences(of: "'\\''", with: "'")
  }
}
#endif
