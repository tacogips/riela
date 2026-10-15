import Foundation
import RielaCore

/// Native dependencies may access only files already exposed to the guest.
struct NativeAddonWorkspacePaths: Sendable {
  var workingDirectory: URL
  var mounts: [WorkflowAddonContainerMount]

  var exposedRoots: [URL] {
    [workingDirectory] + mounts.map {
      $0.source.hasPrefix("/") ? URL(fileURLWithPath: $0.source) : workingDirectory.appendingPathComponent($0.source)
    }
  }

  func hostPath(_ path: String, writing: Bool) throws -> String {
    guard !path.isEmpty, path.utf8.count <= 4_096, !path.contains("\u{0}") else { throw denied() }
    let guest = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : workingDirectory.appendingPathComponent(path))
      .standardizedFileURL.path
    let workspace = WorkflowAddonContainerMount(source: workingDirectory.path, target: workingDirectory.path, readOnly: false)
    let candidates = ([workspace] + mounts).map { mount in
      var canonical = mount
      canonical.target = URL(fileURLWithPath: mount.target).standardizedFileURL.path
      return canonical
    }.sorted { $0.target.count > $1.target.count }
    guard let mount = candidates.first(where: { guest == $0.target || guest.hasPrefix($0.target + "/") }),
          !writing || !mount.readOnly else { throw denied() }
    let source = (mount.source.hasPrefix("/") ? URL(fileURLWithPath: mount.source) : workingDirectory.appendingPathComponent(mount.source))
      .resolvingSymlinksInPath().standardizedFileURL
    let relative = String(guest.dropFirst(mount.target.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let resolved = try resolvingExistingParent(source.appendingPathComponent(relative)).path
    guard resolved == source.path || resolved.hasPrefix(source.path + "/") else { throw denied() }
    return resolved
  }

  func nativeArguments(_ arguments: [String]) throws -> [String] {
    let pathOptions: Set<String> = ["--config", "--query-file", "--variables-file", "--output-dir"]
    let valueOptions = pathOptions.union(["--query", "--variables", "--role", "--domain", "--key"])
    var result = arguments
    var index = 0
    while index < result.count {
      let option = result[index]
      if valueOptions.contains(option) {
        guard index + 1 < result.count else { throw denied() }
        if pathOptions.contains(option) { result[index + 1] = try hostPath(result[index + 1], writing: option == "--output-dir") }
        index += 2
      } else {
        index += 1
      }
    }
    return result
  }

  private struct ArgumentScope {
    var arguments: [String]
    var files: [NativeAddonPinnedFile] = []
    var directories: [NativeAddonPinnedDirectory] = []
    var translations: [String: String] = [:]
  }

  func withNativeArguments<Result>(_ arguments: [String], body: ([String]) throws -> Result) throws -> Result {
    let scope = try argumentScope(arguments)
    defer { withExtendedLifetime(scope) {} }
    return try body(scope.arguments)
  }

  func withGatewayArguments(_ arguments: [String], deadline: Date? = nil, body: ([String]) throws -> AppleGatewayProcessOutput) throws -> AppleGatewayProcessOutput {
    let scope = try argumentScope(arguments)
    defer { withExtendedLifetime(scope) {} }
    var output = try body(scope.arguments)
    if output.terminationStatus == 0 { for directory in scope.directories { try directory.publishFiles(deadline: deadline) } }
    if let data = output.stdout.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
      let translated = translatedPaths(value, translations: scope.translations)
      output.stdout = String(data: try JSONEncoder().encode(translated), encoding: .utf8) ?? output.stdout
    } else {
      for (descriptor, original) in scope.translations { output.stdout = output.stdout.replacingOccurrences(of: descriptor, with: original) }
    }
    for (descriptor, original) in scope.translations { output.stderr = output.stderr.replacingOccurrences(of: descriptor, with: original) }
    return output
  }

  private func argumentScope(_ arguments: [String]) throws -> ArgumentScope {
    var scope = ArgumentScope(arguments: try nativeArguments(arguments))
    let valueOptions: Set<String> = ["--config", "--query-file", "--variables-file", "--output-dir", "--query", "--variables", "--role", "--domain", "--key"]
    var index = 0
    while index < scope.arguments.count {
      let option = scope.arguments[index]
      if valueOptions.contains(option) {
        guard index + 1 < scope.arguments.count else { throw denied() }
        if ["--config", "--query-file", "--variables-file"].contains(option) {
          let file = try NativeAddonPinnedFile(path: scope.arguments[index + 1])
          if option == "--config" {
            scope.files.append(file)
            let descriptor = try file.snapshotDescriptorPath()
            scope.translations[descriptor] = arguments[index + 1]
            scope.arguments[index + 1] = descriptor
          } else {
            scope.arguments[index] = option == "--query-file" ? "--query" : "--variables"
            scope.arguments[index + 1] = try file.text()
          }
        } else if option == "--output-dir" {
          let roots = [workingDirectory.resolvingSymlinksInPath().path] + mounts.map { mount in
            (mount.source.hasPrefix("/") ? URL(fileURLWithPath: mount.source) : workingDirectory.appendingPathComponent(mount.source))
              .resolvingSymlinksInPath().path
          }
          let directory = try NativeAddonPinnedDirectory(path: scope.arguments[index + 1], exposedRoots: roots)
          scope.directories.append(directory)
          let guestPath = arguments[index + 1].hasPrefix("/") ? URL(fileURLWithPath: arguments[index + 1])
            : workingDirectory.appendingPathComponent(arguments[index + 1])
          scope.translations[directory.descriptorPath] = guestPath.standardizedFileURL.path
          scope.arguments[index + 1] = directory.descriptorPath
        }
        index += 2
      } else { index += 1 }
    }
    return scope
  }

  private func translatedPaths(_ value: JSONValue, translations: [String: String]) -> JSONValue {
    switch value {
    case let .object(object):
      var result = object.mapValues { translatedPaths($0, translations: translations) }
      for key in ["path", "localPath", "sourcePath", "configPath"] {
        guard case let .string(path)? = object[key] else { continue }
        for (descriptor, guest) in translations {
          if path == descriptor || path.hasPrefix(descriptor + "/") {
            result[key] = .string(guest + path.dropFirst(descriptor.count))
          }
        }
      }
      return .object(result)
    case let .array(array):
      return .array(array.map { translatedPaths($0, translations: translations) })
    case .string:
      // Path fields are translated below without changing user content strings.
      return value
    default: return value
    }
  }

  private func resolvingExistingParent(_ url: URL) throws -> URL {
    var ancestor = url
    var suffix: [String] = []
    while !FileManager.default.fileExists(atPath: ancestor.path) {
      let attributes = try? FileManager.default.attributesOfItem(atPath: ancestor.path)
      guard attributes?[.type] as? FileAttributeType != .typeSymbolicLink,
            ancestor.path != "/", suffix.count < 256 else { throw denied() }
      suffix.append(ancestor.lastPathComponent)
      ancestor.deleteLastPathComponent()
    }
    var result = ancestor.resolvingSymlinksInPath().standardizedFileURL
    for component in suffix.reversed() { result.appendPathComponent(component) }
    return result.standardizedFileURL
  }

  private func denied() -> AdapterExecutionError {
    AdapterExecutionError(.policyBlocked, "native dependency file access exceeds the guest workspace and mounts")
  }
}
