import Crypto
import Foundation

public enum WorkflowPackageChecksum {
  public static let supportedAlgorithm = "md5"

  private static let ignoredEntryNames = [
    WorkflowPackageArchiveManager.manifestFileName,
    ".DS_Store",
    "__MACOSX",
    ".git",
    ".hg",
    ".svn"
  ]

  public static func md5(packageRoot: URL) throws -> String {
    let packageRoot = packageRoot.standardizedFileURL
    let files = try checksumFiles(packageRoot: packageRoot)
    var payload = Data()
    for file in files {
      payload.append(Data("path:\(relativePath(for: file, packageRoot: packageRoot))\n".utf8))
      payload.append(try Data(contentsOf: file))
      payload.append(Data("\n".utf8))
    }
    return Insecure.MD5.hash(data: payload).map { String(format: "%02x", $0) }.joined()
  }

  public static func validate(
    manifest: WorkflowPackageManifest,
    packageRoot: URL
  ) -> WorkflowPackageValidationIssue? {
    guard manifest.checksumAlgorithm == supportedAlgorithm, let expected = manifest.checksum, !expected.isEmpty else {
      return nil
    }
    do {
      let actual = try md5(packageRoot: packageRoot)
      guard actual != expected else {
        return nil
      }
      return WorkflowPackageValidationIssue(
        code: "CHECKSUM_MISMATCH",
        path: "checksum",
        message: "checksum does not match package contents: expected \(expected), actual \(actual). "
          + "Regenerate riela-package.json with `riela package init <package-dir> --overwrite`, then rebuild the archive if needed."
      )
    } catch {
      return WorkflowPackageValidationIssue(
        code: "CHECKSUM_UNAVAILABLE",
        path: "checksum",
        message: "checksum could not be calculated: \(error.localizedDescription)"
      )
    }
  }

  private static func checksumFiles(packageRoot: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
      at: packageRoot,
      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
      options: []
    ) else {
      return []
    }
    var files: [URL] = []
    for case let fileURL as URL in enumerator {
      let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
      if ignoredEntryNames.contains(fileURL.lastPathComponent) {
        if values.isDirectory == true {
          enumerator.skipDescendants()
        }
        continue
      }
      if values.isRegularFile == true {
        files.append(fileURL.standardizedFileURL)
      }
    }
    return files.sorted { lhs, rhs in
      relativePath(for: lhs, packageRoot: packageRoot) < relativePath(for: rhs, packageRoot: packageRoot)
    }
  }

  private static func relativePath(for url: URL, packageRoot: URL) -> String {
    let rootPath = packageRoot.standardizedFileURL.path
    let urlPath = url.standardizedFileURL.path
    if urlPath == rootPath {
      return "."
    }
    return String(urlPath.dropFirst(rootPath.hasSuffix("/") ? rootPath.count : rootPath.count + 1))
  }
}
