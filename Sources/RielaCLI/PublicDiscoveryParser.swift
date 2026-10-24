import CRielaPublicWeb
import Foundation
import RielaCore

struct PublicDiscoveryCandidate {
  var url: String
  var title: String
  var snippet: String
}

enum PublicDiscoveryParser {
  static func parse(provider: String, body: Data) throws -> [PublicDiscoveryCandidate] {
    guard body.count <= 500_000 else { throw PublicWebError.oversized }
    if provider == "bing-rss" {
      return try WebFeedDocument.parse(body).prefix(30).map { .init(url: $0.url, title: $0.title, snippet: $0.body) }
    }
    if provider == "duckduckgo-html" { return try duck(body) }
    guard case let .object(object) = try JSONDecoder().decode(JSONValue.self, from: body) else { throw PublicWebError.invalidDocument }
    if provider == "openrouter-exa" {
      guard case let .array(choices)? = object["choices"], case let .object(choice)? = choices.first,
        case let .object(message)? = choice["message"],
        case let .array(annotations) = message["annotations"] ?? .array([]) else { throw PublicWebError.invalidDocument }
      return Array(annotations.prefix(30).compactMap { value -> PublicDiscoveryCandidate? in
        guard case let .object(item) = value, item["type"] == .string("url_citation"),
          case let .object(citation)? = item["url_citation"], case let .string(link)? = citation["url"] else { return nil }
        return .init(url: link, title: "", snippet: "")
      }.prefix(5))
    }
    guard case let .array(items)? = object[provider == "github-repositories" ? "items" : "hits"] else { throw PublicWebError.invalidDocument }
    return items.prefix(30).compactMap { value in
      guard case let .object(item) = value else { return nil }
      func text(_ key: String) -> String? { if case let .string(value)? = item[key] { return value }; return nil }
      if provider == "github-repositories" {
        guard item["private"] == .bool(false), let link = text("html_url"), let title = text("full_name"),
          item["description"] == nil || item["description"] == .null || text("description") != nil else { return nil }
        return .init(url: link, title: title, snippet: text("description") ?? "")
      }
      var link = text("url") ?? ""
      if link.isEmpty, let id = text("objectID"), id.range(of: #"\A[0-9]+\z"#, options: .regularExpression) != nil {
        link = "https://news.ycombinator.com/item?id=" + id
      }
      guard item["title"] == nil || item["title"] == .null || text("title") != nil,
        item["story_text"] == nil || item["story_text"] == .null || text("story_text") != nil else { return nil }
      return .init(url: link, title: text("title") ?? "", snippet: text("story_text") ?? "")
    }
  }

  static func destination(_ value: String, blocked: [String]) throws -> String {
    guard !value.unicodeScalars.contains(where: { $0.value <= 32 }), value.utf8.count <= 4096 else { throw PublicWebError.invalidInput }
    let safe = try PublicWebHTTP.destination(value, blockedHosts: blocked)
    let host = safe.host
    guard !["localhost", "metadata.google.internal"].contains(host),
      ![".local", ".localhost", ".internal"].contains(where: host.hasSuffix),
      !["bing.com", "duckduckgo.com", "googleadservices.com", "doubleclick.net"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
      !host.hasPrefix("maps.google."), !host.hasPrefix("news.google."),
      var parts = URLComponents(string: safe.url) else { throw PublicWebError.blockedDestination }
    let path = "/" + parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if (host.hasPrefix("www.google.") || host.hasPrefix("google.")) && ["/", "/search", "/maps", "/news"].contains(path) {
      throw PublicWebError.blockedDestination
    }
    parts.queryItems = parts.queryItems?.filter { !$0.name.lowercased().hasPrefix("utm_") && !["gclid", "fbclid"].contains($0.name.lowercased()) }
    if parts.queryItems?.isEmpty == true { parts.query = nil }
    if parts.path.isEmpty { parts.path = "/" }
    guard let result = parts.url?.absoluteString else { throw PublicWebError.invalidInput }; return result
  }

  static func compact(_ value: String, maximum: Int) -> String {
    String(String.UnicodeScalarView(value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(maximum)))
  }

  private static func duck(_ body: Data) throws -> [PublicDiscoveryCandidate] {
    // libxml memory-only HTML parser: no scripts, browser or entity fetches.
    // swiftlint:disable:next optional_data_string_conversion
    let bytes = Array(String(decoding: body, as: UTF8.self).utf8)
    guard let document = bytes.withUnsafeBytes({ riela_web_parse_html($0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32($0.count)) }) else { throw PublicWebError.invalidDocument }
    defer { xmlFreeDoc(document) }
    guard let root = xmlDocGetRootElement(document) else { throw PublicWebError.invalidDocument }
    var results: [PublicDiscoveryCandidate] = [], visited = 0
    func property(_ node: xmlNodePtr, _ key: String) -> String? {
      let bytes = Array(key.utf8) + [0]
      guard let value = bytes.withUnsafeBufferPointer({ xmlGetProp(node, $0.baseAddress) }) else { return nil }
      defer { riela_web_xml_string_free(value) }; return String(cString: value)
    }
    func text(_ node: xmlNodePtr, depth: Int = 0) throws -> String {
      visited += 1; guard visited <= 100_000, depth <= 128 else { throw PublicWebError.oversized }
      if node.pointee.type == XML_TEXT_NODE, let value = node.pointee.content { return String(cString: value) }
      let name = node.pointee.name.map { String(cString: $0).lowercased() } ?? ""
      if ["script", "style", "template", "noscript"].contains(name) { return "" }
      var parts: [String] = [], child = node.pointee.children
      while let current = child { parts.append(try text(current, depth: depth + 1)); child = current.pointee.next }
      return parts.joined(separator: " ")
    }
    func visit(_ node: xmlNodePtr, depth: Int) throws {
      visited += 1; guard visited <= 100_000, depth <= 128 else { throw PublicWebError.oversized }
      let name = node.pointee.name.map { String(cString: $0).lowercased() } ?? ""
      if ["script", "style", "template", "noscript"].contains(name) { return }
      if name == "a", property(node, "class")?.split(whereSeparator: \.isWhitespace).contains("result__a") == true, results.count < 30 {
        var link = property(node, "href") ?? ""
        if let absolute = URL(string: link, relativeTo: URL(string: "https://html.duckduckgo.com/"))?.absoluteURL,
          let parts = URLComponents(url: absolute, resolvingAgainstBaseURL: true) {
          if ["duckduckgo.com", "html.duckduckgo.com"].contains(parts.host), parts.path == "/l/" {
            let targets = parts.queryItems?.filter { $0.name == "uddg" } ?? []
            if targets.count == 1, let value = targets[0].value { link = value } else { link = "" }
          } else if link.hasPrefix("//") { link = absolute.absoluteString }
        }
        results.append(.init(url: link, title: try text(node), snippet: ""))
        return
      }
      var child = node.pointee.children
      while let current = child { try visit(current, depth: depth + 1); child = current.pointee.next }
    }
    try visit(root, depth: 0); return results
  }
}
