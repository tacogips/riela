import Foundation

public struct WorkflowAuthoredFileOverlay: Codable, Equatable, Sendable {
  public private(set) var files: [String: String]

  public init(files: [String: String]) throws {
    var normalized: [String: String] = [:]
    for (path, text) in files {
      let key = try Self.normalize(path)
      guard normalized[key] == nil else {
        throw WorkflowAuthoredFileOverlayError.invalidPath(path)
      }
      normalized[key] = text
    }
    self.files = normalized
  }

  public func text(at fileURL: URL, workflowDirectory: URL) -> String? {
    let root = workflowDirectory.resolvingSymlinksInPath().standardizedFileURL
    let file = fileURL.resolvingSymlinksInPath().standardizedFileURL
    let rootPath = root.path
    let relativePath: Substring
    if rootPath == "/" {
      guard file.path.hasPrefix("/") else { return nil }
      relativePath = file.path.dropFirst()
    } else {
      guard file.path.hasPrefix(rootPath + "/") else { return nil }
      relativePath = file.path.dropFirst(rootPath.count + 1)
    }
    return files[String(relativePath)]
  }

  public static func normalize(_ path: String) throws -> String {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\"),
          path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) == nil else {
      throw WorkflowAuthoredFileOverlayError.invalidPath(path)
    }
    let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    var normalized: [String] = []
    for segment in segments {
      if segment == "." { continue }
      guard segment != ".." else { throw WorkflowAuthoredFileOverlayError.invalidPath(path) }
      normalized.append(segment)
    }
    guard !normalized.isEmpty else { throw WorkflowAuthoredFileOverlayError.invalidPath(path) }
    return normalized.joined(separator: "/")
  }
}

public enum WorkflowAuthoredFileOverlayError: Error, Equatable, Sendable {
  case invalidPath(String)
}
