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
    guard let definitions = root["workflowDefinitions"] else { return nil }
    guard let values = definitions as? [String: Any] else {
      throw ConfigurationError(description: "workflowDefinitions in \(url.path) must be an object")
    }
    let unknown = Set(values.keys).subtracting(["historyRetention"])
    guard unknown.isEmpty else {
      throw ConfigurationError(description: "unknown workflowDefinitions configuration key: \(unknown.sorted().joined(separator: ", "))")
    }
    guard let raw = values["historyRetention"] else { return nil }
    guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.rounded(.towardZero) == number.doubleValue,
          (0...10_000).contains(number.intValue) else {
      throw ConfigurationError(description: "workflowDefinitions.historyRetention in \(url.path) must be an integer between 0 and 10000")
    }
    return number.intValue
  }
}
