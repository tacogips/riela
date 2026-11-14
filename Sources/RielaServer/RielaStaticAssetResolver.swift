import Foundation

public struct RielaStaticAssetResolver: Sendable {
  public var rootURL: URL

  public init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
  }

  public func response(for request: RielaHTTPRequest) -> RielaHTTPResponse? {
    guard request.method == "GET" || request.method == "HEAD" else {
      return nil
    }
    guard !request.path.hasPrefix("/api/"),
          request.path != "/healthz",
          request.path != "/overview",
          request.path != "/graphql",
          request.path != "/note/register" else {
      return nil
    }
    let requestedPath = request.path == "/" ? "index.html" : String(request.path.dropFirst())
    if let response = fileResponse(relativePath: requestedPath) {
      return response
    }
    guard !requestedPath.split(separator: "/").last.map({ $0.contains(".") })! else {
      return RielaHTTPResponse.text(status: 404, "Not Found")
    }
    return fileResponse(relativePath: "index.html") ?? RielaHTTPResponse.text(status: 404, "Not Found")
  }

  private func fileResponse(relativePath: String) -> RielaHTTPResponse? {
    guard !relativePath.isEmpty,
          !relativePath.contains(".."),
          !relativePath.contains("\\") else {
      return nil
    }
    let candidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
    let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
    guard candidate.path.hasPrefix(rootPath) else {
      return nil
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
          !isDirectory.boolValue,
          let data = try? Data(contentsOf: candidate, options: .mappedIfSafe) else {
      return nil
    }
    let immutable = candidate.lastPathComponent.contains("-") && candidate.pathExtension != "html"
    return RielaHTTPResponse(
      status: 200,
      headers: [
        "Content-Type": Self.contentType(for: candidate.pathExtension),
        "Cache-Control": immutable ? "public, max-age=31536000, immutable" : "no-cache",
        "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'"
      ],
      body: data
    )
  }

  private static func contentType(for pathExtension: String) -> String {
    switch pathExtension.lowercased() {
    case "html": "text/html; charset=utf-8"
    case "js", "mjs": "text/javascript; charset=utf-8"
    case "css": "text/css; charset=utf-8"
    case "json", "map": "application/json; charset=utf-8"
    case "svg": "image/svg+xml"
    case "png": "image/png"
    case "jpg", "jpeg": "image/jpeg"
    case "ico": "image/x-icon"
    case "woff": "font/woff"
    case "woff2": "font/woff2"
    default: "application/octet-stream"
    }
  }
}
