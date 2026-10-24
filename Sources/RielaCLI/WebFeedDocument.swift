import CRielaPublicWeb
import Foundation

struct WebFeedEntry: Sendable {
  let identity: String
  let title: String
  let body: String
  let url: String
  let published: String
}

enum WebFeedDocument {
  static func parse(_ data: Data, entities: [String: String] = [:]) throws -> [WebFeedEntry] {
    guard data.count <= 2_000_000 else { throw PublicWebError.oversized }
    let bytes = Array(try normalized(data, entities: entities))
    guard let document = bytes.withUnsafeBytes({ riela_web_parse_xml($0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32($0.count)) }) else {
      throw PublicWebError.invalidDocument
    }
    defer { xmlFreeDoc(document) }
    guard let root = xmlDocGetRootElement(document) else { throw PublicWebError.invalidDocument }
    let atom = namespace(root) == "http://www.w3.org/2005/Atom" && name(root) == "feed"
    guard atom || (namespace(root).isEmpty && name(root) == "rss") else { throw PublicWebError.invalidDocument }
    var pending: [(xmlNodePtr, Int)] = [(root, 0)], entries: [WebFeedEntry] = [], count = 0
    while let (node, depth) = pending.popLast() {
      count += 1
      guard count <= 100_000, depth <= 128, entries.count <= 10_000 else { throw PublicWebError.oversized }
      if node.pointee.type == XML_ELEMENT_NODE && ((!atom && name(node) == "item" && namespace(node).isEmpty) ||
        (atom && depth == 1 && name(node) == "entry" && namespace(node) == "http://www.w3.org/2005/Atom")) {
        guard entries.count < 10_000 else { throw PublicWebError.oversized }
        entries.append(entry(node))
      }
      var children: [xmlNodePtr] = [], child = node.pointee.children
      while let current = child { children.append(current); child = current.pointee.next }
      pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
    }
    return entries
  }

  private static func entry(_ node: xmlNodePtr) -> WebFeedEntry {
    var fields: [String: String] = [:], atomLink: String?
    var child = node.pointee.children
    while let current = child {
      defer { child = current.pointee.next }
      guard current.pointee.type == XML_ELEMENT_NODE,
        namespace(current).isEmpty || namespace(current) == "http://www.w3.org/2005/Atom" else { continue }
      let key = name(current)
      if fields[key] == nil, let text = xmlNodeGetContent(current) {
        fields[key] = String(cString: text); riela_web_xml_string_free(text)
      }
      if key == "link", namespace(current) == "http://www.w3.org/2005/Atom", atomLink == nil {
        let property: [UInt8] = Array("href".utf8) + [0]
        if let value = property.withUnsafeBufferPointer({ xmlGetProp(current, $0.baseAddress) }) {
          atomLink = String(cString: value); riela_web_xml_string_free(value)
        }
      }
    }
    let link = fields["link"].flatMap { $0.isEmpty ? nil : $0 } ?? atomLink ?? ""
    return .init(identity: fields["guid"].flatMap { $0.isEmpty ? nil : $0 } ?? fields["id"].flatMap { $0.isEmpty ? nil : $0 } ?? link,
      title: fields["title"] ?? "", body: ["description", "summary", "content"].compactMap { fields[$0] }.first { !$0.isEmpty } ?? "",
      url: link, published: ["pubDate", "published", "updated"].compactMap { fields[$0] }.first { !$0.isEmpty } ?? "")
  }

  static func validEntities(_ entities: [String: String]) -> Bool {
    entities.count <= 2500 && entities.allSatisfy { name, value in
      name.utf8.count <= 64 && name.range(of: #"^[A-Za-z][A-Za-z0-9]+$"#, options: .regularExpression) != nil &&
        (1...8).contains(value.unicodeScalars.count)
    }
  }

  private static func normalized(_ data: Data, entities: [String: String]) throws -> Data {
    guard validEntities(entities) else { throw PublicWebError.invalidInput }
    guard !entities.isEmpty else { return data }
    guard let text = String(data: data, encoding: .utf8) else { throw PublicWebError.invalidDocument }
    let source = text as NSString
    let regex = try NSRegularExpression(pattern: #"<!\[CDATA\[.*?\]\]>|&([A-Za-z][A-Za-z0-9]+);"#, options: .dotMatchesLineSeparators)
    var result = "", offset = 0, total = 0
    func append(_ piece: String) throws {
      total += piece.utf8.count
      guard total <= 8_000_000 else { throw PublicWebError.oversized }
      result += piece
    }
    for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
      try append(source.substring(with: NSRange(location: offset, length: match.range.location - offset)))
      let range = match.range(at: 1)
      if range.location != NSNotFound {
        let name = source.substring(with: range)
        if !["amp", "lt", "gt", "apos", "quot"].contains(name), let value = entities[name] {
          try append(value.unicodeScalars.map { "&#\($0.value);" }.joined())
        } else { try append(source.substring(with: match.range)) }
      } else { try append(source.substring(with: match.range)) }
      offset = match.range.location + match.range.length
    }
    try append(source.substring(from: offset))
    guard result.utf8.count <= 8_000_000 else { throw PublicWebError.oversized }
    return Data(result.utf8)
  }

  private static func name(_ node: xmlNodePtr) -> String { node.pointee.name.map { String(cString: $0) } ?? "" }
  private static func namespace(_ node: xmlNodePtr) -> String { node.pointee.ns?.pointee.href.map { String(cString: $0) } ?? "" }
}
