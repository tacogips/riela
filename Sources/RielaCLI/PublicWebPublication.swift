import CRielaPublicWeb
import Foundation
import RielaCore

/// Explicit URL-bound publication policy. Never falls back to a modification
/// date, a different page's metadata or the acquisition time.
enum PublicWebPublication {
  static func date(_ data: Data, url: String, type: String) throws -> WebCollectionTimestamp? {
    guard data.count <= 8_000_000 else { throw PublicWebError.oversized }
    // swiftlint:disable:next optional_data_string_conversion
    let bytes = Array(String(decoding: data, as: UTF8.self).utf8)
    guard let document = bytes.withUnsafeBytes({ riela_web_parse_html($0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32($0.count)) }) else { throw PublicWebError.invalidDocument }
    defer { xmlFreeDoc(document) }
    guard let root = xmlDocGetRootElement(document) else { return nil }
    var documents: [JSONValue] = [], count = 0
    func visit(_ node: xmlNodePtr, depth: Int) throws {
      count += 1
      guard depth <= 128, count <= 100_000 else { throw PublicWebError.oversized }
      if node.pointee.type == XML_ELEMENT_NODE, node.pointee.name.map({ String(cString: $0).lowercased() }) == "script" {
        let name = Array("type".utf8) + [0]
        let raw = name.withUnsafeBufferPointer { xmlGetProp(node, $0.baseAddress) }
        let mime = raw.map { String(cString: $0).components(separatedBy: ";")[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if let raw { riela_web_xml_string_free(raw) }
        if mime == "application/ld+json", documents.count < 10, let content = xmlNodeGetContent(node) {
          defer { riela_web_xml_string_free(content) }
          let text = String(cString: content)
          if text.utf8.count <= 200_000, let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) {
            documents.append(value)
          }
        }
      }
      var child = node.pointee.children
      while let current = child { try visit(current, depth: depth + 1); child = current.pointee.next }
    }
    try visit(root, depth: 0)
    var dates: [WebCollectionTimestamp] = [], invalid = false, nodes = 0
    func inspect(_ value: JSONValue, depth: Int) throws {
      nodes += 1
      guard depth <= 128, nodes <= 10_000 else { throw PublicWebError.oversized }
      switch value {
      case let .array(items): for item in items { try inspect(item, depth: depth + 1) }
      case let .object(item):
        if item["@type"] == .string(type), case let .object(page)? = item["mainEntityOfPage"],
          page["@type"] == .string("WebPage"), page["@id"] == .string(url) {
          if let raw = webCollectionText(item["datePublished"]), raw.utf8.count <= 80, let date = WebCollectionTimestamp(raw),
            raw.range(of: #"^\d{4}-\d{2}-\d{2}[Tt ]"#, options: .regularExpression) != nil { dates.append(date) } else { invalid = true }
        }
        if case let .array(graph)? = item["@graph"] { try inspect(.array(graph), depth: depth + 1) }
      default: break
      }
    }
    for document in documents { try inspect(document, depth: 0) }
    guard !invalid, let first = dates.first, dates.allSatisfy({ $0.date == first.date }) else { return nil }
    return first
  }
}
