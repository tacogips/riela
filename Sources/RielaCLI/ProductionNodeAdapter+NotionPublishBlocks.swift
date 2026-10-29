import Foundation
import RielaAddonSupport
import RielaCore

struct DeferredNotionChildren {
  var parentPath: [Int]
  var offset: Int
  var children: [JSONValue]
}

func normalizeNotionBlock(_ block: JSONValue, uploadIds: [String: String], failures: inout [JSONValue], paths: [String: String], allowAttachments: Bool, baseDirectory: URL) -> [JSONValue] {
  guard case var .object(object) = block else { return [block] }
  if object["type"] == nil {
    let contentKeys = object.keys.filter { $0 != "object" && $0 != "children" && $0 != "id" }
    if contentKeys.count == 1 {
      object["type"] = .string(contentKeys[0])
    } else {
      // Keep walking untyped wrappers so local_file values are never sent raw.
      for key in Array(object.keys) {
        if case let .array(children)? = object[key] {
          object[key] = .array(children.flatMap { normalizeNotionBlock($0, uploadIds: uploadIds, failures: &failures, paths: paths, allowAttachments: allowAttachments, baseDirectory: baseDirectory) })
        } else if let value = object[key], var body = ifObject(value), case let .array(children)? = body["children"] {
          body["children"] = .array(children.flatMap { normalizeNotionBlock($0, uploadIds: uploadIds, failures: &failures, paths: paths, allowAttachments: allowAttachments, baseDirectory: baseDirectory) })
          object[key] = .object(body)
        }
      }
      return [.object(object)]
    }
  }
  guard let type = notionString(object["type"]) else { return [block] }
  if ["image", "file"].contains(type), case var .object(payload)? = object[type], payload["type"] == .string("local_file") {
    let local = payload["local_file"].flatMap(ifObject)
    let path = local.flatMap { nonEmptyString($0["path"]) }
    let standardized = path.map { URL(fileURLWithPath: $0, relativeTo: baseDirectory).standardizedFileURL.path } ?? ""
    if let id = (type == "file" && !allowAttachments) ? nil : uploadIds[standardized] {
      payload["type"] = .string("file_upload"); payload["file_upload"] = .object(["id": .string(id)])
      payload.removeValue(forKey: "local_file"); object[type] = .object(payload)
    } else {
      let basename = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown"
      if !failures.contains(where: { notionString(ifObject($0)?["path"]) == standardized }) {
        failures.append(.object(["path": .string(standardized), "message": .string(type == "file" && !allowAttachments ? "local file attachments are disabled" : "local_file path is missing or upload failed")]))
      }
      return [paragraphText("[\(type == "image" ? "画像" : "ファイル")を保存できませんでした: \(basename)]")]
    }
  }
  for key in Array(object.keys) {
    if key == "children", case let .array(children)? = object[key] {
      object[key] = .array(children.flatMap { normalizeNotionBlock($0, uploadIds: uploadIds, failures: &failures, paths: paths, allowAttachments: allowAttachments, baseDirectory: baseDirectory) })
    } else if let value = object[key], var body = ifObject(value), case let .array(children)? = body["children"] {
      body["children"] = .array(children.flatMap { normalizeNotionBlock($0, uploadIds: uploadIds, failures: &failures, paths: paths, allowAttachments: allowAttachments, baseDirectory: baseDirectory) })
      object[key] = .object(body)
    }
  }
  var extraTextBlocks: [JSONValue] = []
  if case var .object(body)? = object[type], case let .array(richText)? = body["rich_text"] {
    var retained: [JSONValue] = []
    var overflow: [JSONValue] = []
    for item in richText {
      guard case let .object(itemObject) = item else {
        if retained.count < 100 { retained.append(item) } else { overflow.append(item) }
        continue
      }
      if case let .object(text)? = itemObject["text"], case let .string(content)? = text["content"], content.utf16.count > 2_000 {
        let pieces = splitUTF16(content, maxUnits: 2_000)
        let items = pieces.map { piece -> JSONValue in
          var copy = itemObject
          var copiedText = text
          copiedText["content"] = .string(piece)
          copy["text"] = .object(copiedText)
          return .object(copy)
        }
        for item in items {
          if retained.count < 100 { retained.append(item) } else { overflow.append(item) }
        }
        continue
      }
      let normalized = JSONValue.object(itemObject)
      if retained.count < 100 { retained.append(normalized) } else { overflow.append(normalized) }
    }
    body["rich_text"] = .array(retained)
    for batch in stride(from: 0, to: overflow.count, by: 100) {
      var overflowBody = body
      overflowBody.removeValue(forKey: "children")
      overflowBody["rich_text"] = .array(Array(overflow[batch..<min(batch + 100, overflow.count)]))
      extraTextBlocks.append(.object(["object": .string("block"), "type": .string(type), type: .object(overflowBody)]))
    }
    object[type] = .object(body)
  } else if case let .object(body)? = object[type] {
    object[type] = .object(body)
  }
  return [.object(object)] + extraTextBlocks
}

private func splitUTF16(_ value: String, maxUnits: Int) -> [String] {
  var result: [String] = []
  var current = ""
  var units = 0
  for scalar in value.unicodeScalars {
    let count = scalar.value > 0xFFFF ? 2 : 1
    if units + count > maxUnits, !current.isEmpty { result.append(current); current = ""; units = 0 }
    current.unicodeScalars.append(scalar)
    units += count
  }
  if !current.isEmpty { result.append(current) }
  return result
}

private func paragraphText(_ text: String) -> JSONValue {
  paragraphBlock([.object(["type": .string("text"), "text": .object(["content": .string(text)])])])
}

private func paragraphBlock(_ richText: [JSONValue]) -> JSONValue {
  .object(["object": .string("block"), "type": .string("paragraph"), "paragraph": .object(["rich_text": .array(richText)])])
}

func notionBlockCount(_ blocks: [JSONValue]) -> Int {
  blocks.reduce(into: 0) { count, block in
    count += 1
    guard case let .object(object) = block else { return }
    if case let .array(children)? = object["children"] { count += notionBlockCount(children) }
    for (key, value) in object where key != "children" {
      if case let .object(body) = value, case let .array(children)? = body["children"] {
        count += notionBlockCount(children)
      }
    }
  }
}

func notionBlockChunks(_ blocks: [JSONValue]) throws -> [[JSONValue]] {
  var chunks: [[JSONValue]] = []
  var current: [JSONValue] = []
  var currentSize = 2
  var currentCount = 0
  for block in blocks {
    let blockSize = try block.compactJSONString().utf8.count
    let blockCount = notionBlockCount([block])
    let candidateSize = currentSize + blockSize + (current.isEmpty ? 0 : 1)
    if !current.isEmpty && (current.count >= 100 || currentCount + blockCount > 900 || candidateSize > 399_488) {
      chunks.append(current)
      current = [block]
      currentSize = blockSize + 2
      currentCount = blockCount
    } else {
      current.append(block)
      currentSize = candidateSize
      currentCount += blockCount
    }
  }
  if !current.isEmpty { chunks.append(current) }
  return chunks
}

func requireNotionPageID(_ id: String?, addonName: String) throws -> String {
  guard let id, !id.isEmpty else { throw AdapterExecutionError(.invalidOutput, "\(addonName) page id is unavailable") }
  return id
}

func indexNotionResultIDs(_ result: JSONObject, offset: Int, path: [Int], into ids: inout [String: String]) {
  guard case let .array(results)? = result["results"] else { return }
  for (index, item) in results.enumerated() {
    guard case let .object(block) = item else { continue }
    let blockPath = path + [offset + index]
    if let id = nonEmptyString(block["id"]) { ids[blockPath.map(String.init).joined(separator: ".")] = id }
    indexNotionNestedResultIDs(in: block, path: blockPath, into: &ids)
  }
}

private func indexNotionNestedResultIDs(in object: JSONObject, path: [Int], into ids: inout [String: String]) {
  for value in object.values {
    switch value {
    case let .object(body):
      if case .array? = body["results"] {
        indexNotionResultIDs(body, offset: 0, path: path, into: &ids)
      } else {
        indexNotionNestedResultIDs(in: body, path: path, into: &ids)
      }
    case let .array(values):
      for value in values {
        guard case let .object(body) = value else { continue }
        indexNotionNestedResultIDs(in: body, path: path, into: &ids)
      }
    default:
      continue
    }
  }
}

func stripDeepNotionChildren(_ blocks: [JSONValue]) -> ([JSONValue], [DeferredNotionChildren]) {
  var deferred: [DeferredNotionChildren] = []
  let shallow = blocks.enumerated().map { index, block in
    stripDeepNotionChildren(block, depth: 1, path: [index], deferred: &deferred)
  }
  return (shallow, deferred)
}

func stripDeepNotionChildren(
  _ block: JSONValue,
  depth: Int,
  path: [Int],
  deferred: inout [DeferredNotionChildren]
) -> JSONValue {
  guard case var .object(object) = block, case let .string(type)? = object["type"] else { return block }
  let subtreeCount = notionBlockCount([block])
  let subtreeSize = (try? block.compactJSONString().utf8.count) ?? 0
  let subtreeExceedsRequestBudget = subtreeCount > 900 || subtreeSize > 399_488
  for key in Array(object.keys) {
    if key == "children", case let .array(children)? = object[key] {
      if type == "table", children.count > 100, depth < 3 {
        object[key] = .array(Array(children.prefix(100)))
        deferred.append(DeferredNotionChildren(parentPath: path, offset: 100, children: Array(children.dropFirst(100))))
      } else if ["column", "column_list"].contains(type), children.count > 100 || subtreeExceedsRequestBudget {
        let firstChunk = (try? notionBlockChunks(children))?.first ?? []
        let retainedCount = max(1, firstChunk.count)
        object[key] = .array(Array(children.prefix(retainedCount)))
        deferred.append(DeferredNotionChildren(parentPath: path, offset: retainedCount, children: Array(children.dropFirst(retainedCount))))
      } else if depth >= 3 || children.count > 100 || subtreeExceedsRequestBudget {
        object.removeValue(forKey: key)
        deferred.append(DeferredNotionChildren(parentPath: path, offset: 0, children: children))
      } else {
        object[key] = .array(stripNotionChildList(children, depth: depth, path: path, deferred: &deferred))
      }
    } else if let value = object[key], var body = ifObject(value), case let .array(children)? = body["children"] {
      if type == "table", children.count > 100, depth < 3 {
        body["children"] = .array(Array(children.prefix(100)))
        object[key] = .object(body)
        deferred.append(DeferredNotionChildren(parentPath: path, offset: 100, children: Array(children.dropFirst(100))))
      } else if ["column", "column_list"].contains(type), children.count > 100 || subtreeExceedsRequestBudget {
        let firstChunk = (try? notionBlockChunks(children))?.first ?? []
        let retainedCount = max(1, firstChunk.count)
        body["children"] = .array(Array(children.prefix(retainedCount)))
        object[key] = .object(body)
        deferred.append(DeferredNotionChildren(parentPath: path, offset: retainedCount, children: Array(children.dropFirst(retainedCount))))
      } else if depth >= 3 || children.count > 100 || subtreeExceedsRequestBudget {
        body.removeValue(forKey: "children")
        object[key] = .object(body)
        deferred.append(DeferredNotionChildren(parentPath: path, offset: 0, children: children))
      } else {
        body["children"] = .array(stripNotionChildList(children, depth: depth, path: path, deferred: &deferred))
        object[key] = .object(body)
      }
    }
  }
  return .object(object)
}

private func stripNotionChildList(
  _ children: [JSONValue],
  depth: Int,
  path: [Int],
  deferred: inout [DeferredNotionChildren]
) -> [JSONValue] {
  var retained: [JSONValue] = []
  for (index, child) in children.enumerated() {
    let childPath = path + [index]
    let childDepth = depth + 1
    let type = (ifObject(child)).flatMap { notionString($0["type"]) }
    let hasChildren = notionBlockCount([child]) > 1
    if hasChildren && ((type == "column_list" && childDepth >= 2) || (type == "table" && childDepth >= 3)) {
      deferred.append(DeferredNotionChildren(parentPath: path, offset: retained.count, children: Array(children[index...])))
      break
    } else {
      retained.append(stripDeepNotionChildren(child, depth: childDepth, path: childPath, deferred: &deferred))
    }
  }
  return retained
}

func notionBlockID(
  at path: [Int],
  pageId: String,
  knownIDs: [String: String],
  runner: @escaping LocalGatewayGraphQLRunner,
  environment: [String: String],
  bindings: [String: String],
  context: AdapterExecutionContext,
  addonName: String
) async throws -> String {
  let components = path.map(String.init)
  var knownPrefixLength = components.count
  var parentId: String?
  while knownPrefixLength > 0 {
    let key = components.prefix(knownPrefixLength).joined(separator: ".")
    if let known = knownIDs[key] { parentId = known; break }
    knownPrefixLength -= 1
  }
  if knownPrefixLength == components.count, let parentId { return parentId }
  var currentParentId = parentId ?? pageId
  for index in components.dropFirst(knownPrefixLength).compactMap(Int.init) {
    var cursor: JSONValue?
    var children: [JSONValue] = []
    repeat {
      var variables: JSONObject = ["id": .string(currentParentId), "pageSize": .integer(100)]
      if let cursor { variables["startCursor"] = cursor }
      let response = try await notionPublishCall(runner: runner,
        document: "query($id:ID!,$pageSize:Int,$startCursor:String){blockChildren(id:$id,pageSize:$pageSize,startCursor:$startCursor)}",
        variables: variables, environment: environment, bindings: bindings, context: context, addonName: addonName)
      let result: JSONObject = response.data.values.first.flatMap { if case let .object(object) = $0 { object } else { nil } } ?? [:]
      if case let .array(page)? = result["results"] { children.append(contentsOf: page) }
      cursor = result["has_more"] == .bool(true) ? result["next_cursor"] : nil
    } while cursor != nil
    guard children.indices.contains(index), case let .object(block) = children[index], let id = nonEmptyString(block["id"]) else {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) could not resolve a Notion block id for nested children")
    }
    currentParentId = id
  }
  return currentParentId
}
