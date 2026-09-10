import Foundation

public enum RielaWebAssetLocator {
  public static func locate(
    bundle: Bundle? = .main,
    executableURL: URL? = Bundle.main.executableURL,
    currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  ) -> URL? {
    var candidates: [URL] = []
    if let resourceURL = bundle?.resourceURL {
      candidates.append(resourceURL.appendingPathComponent("Web", isDirectory: true))
    }
    if let executableURL {
      // Homebrew and manual installations commonly expose the CLI via a symlink.
      let directory = executableURL.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
      for path in ["../Resources/Web", "Web", "../share/riela/web"] {
        candidates.append(directory.appendingPathComponent(path, isDirectory: true))
      }
    }
    candidates.append(currentDirectoryURL.appendingPathComponent("web/dist", isDirectory: true))
    return candidates.map { $0.standardizedFileURL.resolvingSymlinksInPath() }.first(where: isUsableRoot)
  }

  private static func isUsableRoot(_ root: URL) -> Bool {
    let index = root.appendingPathComponent("index.html").resolvingSymlinksInPath()
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    let values = try? index.resourceValues(forKeys: [.isRegularFileKey])
    return index.path.hasPrefix(prefix) && values?.isRegularFile == true
      && FileManager.default.isReadableFile(atPath: index.path)
  }
}
