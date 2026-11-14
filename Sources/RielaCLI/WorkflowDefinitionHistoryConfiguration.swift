import Foundation
import CoreFoundation

enum WorkflowDefinitionHistoryConfiguration {
  static let defaultRetention = 10

  struct ConfigurationError: Error, CustomStringConvertible {
    var description: String
  }

  static func resolve(homeDirectory: String, projectDirectory: String, environment: [String: String]) throws -> Int {
    let projectConfig = URL(fileURLWithPath: projectDirectory, isDirectory: true)
      .appendingPathComponent(".riela/config.json")
    let configuredHome = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? homeDirectory
    let configuredUserConfig = URL(fileURLWithPath: configuredHome, isDirectory: true)
      .appendingPathComponent(".riela/config.json")
    let projectValue = try read(projectConfig)
    let userValue = try read(configuredUserConfig)
    return projectValue ?? userValue ?? defaultRetention
  }

  private static func read(_ url: URL) throws -> Int? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    } catch {
      throw ConfigurationError(description: "could not read workflow definition history configuration at \(url.path): \(error)")
    }
    guard let root = object as? [String: Any] else {
      throw ConfigurationError(description: "configuration at \(url.path) must be a JSON object")
    }
    let workflowDefinitions: [String: Any]
    if let raw = root["workflowDefinitions"] {
      guard let values = raw as? [String: Any] else {
        throw ConfigurationError(description: "workflowDefinitions in \(url.path) must be an object")
      }
      let unknown = Set(values.keys).subtracting(["historyRetention"])
      guard unknown.isEmpty else {
        throw ConfigurationError(description: "unknown workflowDefinitions configuration key: \(unknown.sorted().joined(separator: ", "))")
      }
      workflowDefinitions = values
    } else {
      workflowDefinitions = [:]
    }
    let retention = root["retention"] as? [String: Any]
    let definitionRetention = retention?["definitions"] as? [String: Any]
    if let definitionRetention {
      let unknown = Set(definitionRetention.keys).subtracting(["keepVersions"])
      guard unknown.isEmpty else {
        throw ConfigurationError(description: "unknown retention.definitions configuration key: \(unknown.sorted().joined(separator: ", "))")
      }
    }
    let historyValue = try integer(workflowDefinitions["historyRetention"], key: "workflowDefinitions.historyRetention", minimum: 0, url: url)
    let aliasValue = try integer(definitionRetention?["keepVersions"], key: "retention.definitions.keepVersions", minimum: 0, url: url)
    if let historyValue, let aliasValue, historyValue != aliasValue {
      throw ConfigurationError(description: "workflowDefinitions.historyRetention and retention.definitions.keepVersions in \(url.path) must match")
    }
    return historyValue ?? aliasValue
  }

  private static func integer(_ raw: Any?, key: String, minimum: Int, url: URL) throws -> Int? {
    guard let raw else { return nil }
    guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.rounded(.towardZero) == number.doubleValue,
          (minimum...10_000).contains(number.intValue) else {
      throw ConfigurationError(description: "\(key) in \(url.path) must be an integer between \(minimum) and 10000")
    }
    return number.intValue
  }
}
