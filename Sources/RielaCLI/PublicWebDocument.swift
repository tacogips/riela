import CRielaPublicWeb
import Foundation
import RielaCore

struct PublicWebPageOptions: Sendable {
  var mode = "auto"
  var minimumTextCharacters = 400
  var waitMs = 1500
  var timeoutMs = 20_000
  var maximumTextCharacters = 20_000
}

struct PublicWebPage: Sendable {
  var url: String
  var title: String
  var text: String
  var links: [String]
  var publishedAt: String?
  var canonical: String?
  var metadataOnly: Bool
  var method = "http"

  func payload() -> JSONObject {
    var result: JSONObject = ["kind": .string("web-page"), "url": .string(url), "title": .string(title),
      "text": .string(text), "links": .array(links.map(JSONValue.string)), "method": .string(method),
      "fetched_at": .string(ISO8601DateFormatter().string(from: Date())),
      "content_scope": .string(metadataOnly ? "public-headline-and-lead" : "page"),
      "published_at": publishedAt.map(JSONValue.string) ?? .null]
    if metadataOnly { result["canonical"] = canonical.map(JSONValue.string) ?? .null }
    return result
  }
}

enum PublicWebDocument {
  private struct Region { var priority: Int; var parts: [String] = [] }
  private static let hiddenTags: Set<String> = ["script", "style", "noscript", "iframe", "svg", "template"]

  static func parse(
    _ data: Data, url: String, options: PublicWebPageOptions, metadataOnly: Bool = false,
    keepLink: ((String) -> Bool)? = nil
  ) throws -> PublicWebPage {
    guard data.count <= 8_000_000 else { throw PublicWebError.oversized }
    // Match the prior HTTP reader's bounded UTF-8 replacement behavior. libxml
    // parses only memory and never receives a document URL or entity loader.
    // Invalid UTF-8 is deliberately replaced, matching the HTTP wire contract.
    // swiftlint:disable:next optional_data_string_conversion
    let source = String(decoding: data, as: UTF8.self)
    let bytes = Array(source.utf8)
    guard let document = bytes.withUnsafeBytes({ riela_web_parse_html($0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32($0.count)) }) else { throw PublicWebError.invalidDocument }
    defer { xmlFreeDoc(document) }
    guard let root = xmlDocGetRootElement(document) else { throw PublicWebError.invalidDocument }
    var regions: [Region] = [], parts: [String] = [], titles: [String] = [], links: [String] = []
    var metadata: [String: String] = [:], publishedAt: String?
    var nodes = 0, accumulatedBytes = 0
    var seenLinks: Set<String> = []
    func visit(_ node: xmlNodePtr, depth: Int, hidden: Bool, active: [Int], inTitle: Bool, inHead: Bool) throws {
      nodes += 1
      guard depth <= 128, nodes <= 100_000 else { throw PublicWebError.oversized }
      if node.pointee.type == XML_TEXT_NODE || node.pointee.type == XML_CDATA_SECTION_NODE {
        guard !hidden, let content = node.pointee.content else { return }
        let text = String(cString: content)
        accumulatedBytes += text.utf8.count * (active.count + 1)
        guard accumulatedBytes <= 16_000_000 else { throw PublicWebError.oversized }
        if inTitle { titles.append(text) } else if !metadataOnly { parts.append(text); for index in active { regions[index].parts.append(text) } }
        return
      }
      guard node.pointee.type == XML_ELEMENT_NODE else { return }
      let tag = node.pointee.name.map { String(cString: $0).lowercased() } ?? ""
      let head = inHead || tag == "head"
      let hidden = hidden || hiddenTags.contains(tag) || attribute(node, "hidden") != nil ||
        attribute(node, "aria-hidden")?.lowercased() == "true" ||
        attribute(node, "style")?.range(of: #"(?:^|;)\s*(?:display\s*:\s*none|visibility\s*:\s*hidden)\s*(?:;|$|!)"#,
          options: .caseInsensitive.union(.regularExpression)) != nil
      var active = active
      if !hidden && !metadataOnly && (tag == "article" || tag == "main" || attribute(node, "role")?.lowercased() == "main") {
        guard regions.count < 64 else { throw PublicWebError.oversized }
        active.append(regions.count); regions.append(.init(priority: tag == "article" ? 0 : 1))
      }
      if tag == "meta", !hidden {
        let name = (attribute(node, "property") ?? attribute(node, "name") ?? "").lowercased()
        let value = compact(attribute(node, "content") ?? "", limit: 12_000)
        if ["article:published_time", "datepublished", "date"].contains(name) && (!metadataOnly || head) { publishedAt = compact(value, limit: 80) }
        if head && metadata[name] == nil { metadata[name] = value }
      }
      if tag == "link", head, !hidden, attribute(node, "rel")?.lowercased() == "canonical", metadata["canonical"] == nil {
        metadata["canonical"] = attribute(node, "href").map { compact($0, limit: 4096) }
      }
      if tag == "a", !hidden, let href = attribute(node, "href"),
        links.count < (metadataOnly ? 50 : 200), keepLink?(href) != false,
        seenLinks.insert(href).inserted { links.append(href) }
      var child = node.pointee.children
      while let current = child {
        try visit(current, depth: depth + 1, hidden: hidden, active: active, inTitle: inTitle || tag == "title", inHead: head)
        child = current.pointee.next
      }
    }
    try visit(root, depth: 0, hidden: false, active: [], inTitle: false, inHead: false)
    var candidates: [(priority: Int, text: String)] = []
    for region in regions {
      let text = region.parts.joined(separator: " ")
      let visibleCount = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
      if visibleCount >= 80 { candidates.append((region.priority, text)) }
    }
    candidates.sort { lhs, rhs in
      if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
      return lhs.text.unicodeScalars.count > rhs.text.unicodeScalars.count
    }
    let title = metadataOnly ? (metadata["og:title"].flatMap { $0.isEmpty ? nil : $0 } ?? titles.joined(separator: " ")) : titles.joined(separator: " ")
    let text = metadataOnly ? (metadata["description"].flatMap { $0.isEmpty ? nil : $0 } ?? metadata["og:description"] ?? "") :
      (candidates.first?.1 ?? parts.joined(separator: " "))
    if metadataOnly { publishedAt = ["article:published_time", "datepublished", "date"].compactMap { metadata[$0] }.first { !$0.isEmpty }.map { compact($0, limit: 80) } }
    return .init(url: url, title: compact(title, limit: 500), text: compact(text, limit: options.maximumTextCharacters),
      links: safeLinks(links, base: url), publishedAt: publishedAt, canonical: metadata["canonical"], metadataOnly: metadataOnly)
  }

  static func compact(_ value: String, limit: Int) -> String {
    let compacted = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    return String(String.UnicodeScalarView(compacted.unicodeScalars.prefix(limit)))
  }

  static func safeLinks(_ links: [String], base: String) -> [String] {
    var seen: Set<String> = [], result: [String] = []
    for href in links.prefix(200) {
      guard let url = URL(string: href, relativeTo: URL(string: base))?.absoluteURL,
        url.absoluteString.utf8.count <= 4096, let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
        components.scheme == "https", components.host != nil, components.user == nil, components.password == nil,
        components.port == nil || components.port == 443 else { continue }
      if seen.insert(url.absoluteString).inserted { result.append(url.absoluteString) }
      if result.count == 50 { break }
    }
    return result
  }

  private static func attribute(_ node: xmlNodePtr, _ name: String) -> String? {
    let bytes = Array(name.utf8) + [0]
    guard let value = bytes.withUnsafeBufferPointer({ xmlGetProp(node, $0.baseAddress) }) else { return nil }
    defer { riela_web_xml_string_free(value) }
    return String(cString: value)
  }
}
