import Foundation

enum PublicWebResources {
  // Do not use Bundle.module here: its generated accessor fatalErrors if an
  // optional renderer bundle is absent. Installed CLI resources live in share,
  // whereas SwiftPM/container bundles live beside the executable.
  static func browserScript(
    executable: URL? = Bundle.main.executableURL,
    bundle: URL = Bundle.main.bundleURL,
    resources: URL? = Bundle.main.resourceURL
  ) -> URL? {
    let directory = executable?.resolvingSymlinksInPath().deletingLastPathComponent()
    let roots = [directory, bundle, resources,
      directory?.deletingLastPathComponent().appendingPathComponent("share/riela"),
      bundle.pathExtension == "xctest" ? bundle.deletingLastPathComponent() : nil].compactMap { $0 }
    for root in roots {
      for name in ["riela_RielaCLI.bundle", "riela_RielaCLI.resources"] {
        let candidate = root.appendingPathComponent(name)
        for path in ["PublicWebBrowser.py", "Contents/Resources/PublicWebBrowser.py"] {
          let script = candidate.appendingPathComponent(path)
          if FileManager.default.isReadableFile(atPath: script.path) { return script }
        }
      }
    }
    return nil
  }
}
