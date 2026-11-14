import Foundation
import RielaCore
import RielaMemory

func memoryFileReferences(config: JSONObject, variables: JSONObject) throws -> [MemoryFileReference] {
  let workflowInput = memoryFileObject(variables["workflowInput"])
  let event = memoryFileObject(variables["event"])
  let eventInput = memoryFileObject(event["input"])
  let eventPayload = memoryFileObject(eventInput["payload"])
  let directInput = memoryFileObject(variables["input"])
  let fileValues = [
    config["files"],
    variables["files"],
    workflowInput["files"],
    eventInput["files"],
    eventPayload["files"],
    directInput["files"],
    config["attachments"],
    variables["attachments"],
    workflowInput["attachments"],
    eventInput["attachments"],
    eventPayload["attachments"],
    directInput["attachments"]
  ]
  for value in fileValues {
    if let files = try memoryFileReferences(from: value, variables: variables) {
      return files
    }
  }
  if let configured = try renderedMemoryFilePathArray(
    config["filePaths"],
    variables: variables,
    fieldName: "memory filePaths"
  ) {
    return configured.map { MemoryFileReference(path: $0) }
  }
  if let variablePaths = try renderedMemoryFilePathArray(
    variables["filePaths"],
    variables: variables,
    fieldName: "memory filePaths"
  ) {
    return variablePaths.map { MemoryFileReference(path: $0) }
  }
  if let imagePaths = try renderedMemoryFilePathArray(
    config["imagePaths"],
    variables: variables,
    fieldName: "memory imagePaths"
  ) ?? renderedMemoryFilePathArray(
    variables["imagePaths"],
    variables: variables,
    fieldName: "memory imagePaths"
  ) ?? renderedMemoryFilePathArray(
    workflowInput["imagePaths"],
    variables: variables,
    fieldName: "memory imagePaths"
  ) ?? renderedMemoryFilePathArray(
    eventInput["imagePaths"],
    variables: variables,
    fieldName: "memory imagePaths"
  ) ?? renderedMemoryFilePathArray(
    eventPayload["imagePaths"],
    variables: variables,
    fieldName: "memory imagePaths"
  ) ?? renderedMemoryFilePathArray(
    directInput["imagePaths"],
    variables: variables,
    fieldName: "memory imagePaths"
  ) {
    return imagePaths.map { MemoryFileReference(path: $0, kind: "image") }
  }
  if let singlePath = renderedMemoryFileString(config["filePath"], variables: variables)
    ?? renderedMemoryFileString(variables["filePath"], variables: variables) {
    return [MemoryFileReference(path: singlePath)]
  }
  if let singleImagePath = renderedMemoryFileString(config["imagePath"], variables: variables)
    ?? renderedMemoryFileString(variables["imagePath"], variables: variables) {
    return [MemoryFileReference(path: singleImagePath, kind: "image")]
  }
  return []
}

private func memoryFileObject(_ value: JSONValue?) -> JSONObject {
  guard case let .object(object)? = value else {
    return [:]
  }
  return object
}

private func memoryFileReferences(from value: JSONValue?, variables: JSONObject) throws -> [MemoryFileReference]? {
  guard let value else {
    return nil
  }
  guard case let .array(entries) = value else {
    throw AdapterExecutionError(.policyBlocked, "memory files must be an array")
  }
  return try entries.enumerated().compactMap { index, entry in
    switch entry {
    case let .string(path):
      let renderedPath = renderPromptTemplate(path, variables: variables)
      return renderedPath.isEmpty ? nil : MemoryFileReference(path: renderedPath)
    case let .object(object):
      return try memoryFileReference(from: object, variables: variables, index: index)
    case .null:
      return nil
    case .bool, .number, .array:
      throw AdapterExecutionError(.policyBlocked, "memory files[\(index)] must be a string path or object")
    }
  }
}

private func memoryFileReference(
  from object: JSONObject,
  variables: JSONObject,
  index: Int
) throws -> MemoryFileReference? {
  guard let path = renderedMemoryFileString(object["path"], variables: variables)
    ?? renderedMemoryFileString(object["localPath"], variables: variables)
    ?? renderedMemoryFileString(object["imagePath"], variables: variables)
    ?? renderedMemoryFileString(object["downloadPath"], variables: variables) else {
    return nil
  }
  return MemoryFileReference(
    path: path,
    mediaType: nonEmptyString(object["mediaType"])
      ?? nonEmptyString(object["contentType"])
      ?? nonEmptyString(object["mimetype"])
      ?? nonEmptyString(object["mimeType"]),
    kind: nonEmptyString(object["kind"]),
    name: nonEmptyString(object["name"]) ?? nonEmptyString(object["fileName"]),
    sizeBytes: try memoryFileInt64(object["sizeBytes"], fieldName: "memory files[\(index)].sizeBytes")
      ?? memoryFileInt64(object["fileSize"], fieldName: "memory files[\(index)].fileSize")
  )
}

private func renderedMemoryFilePathArray(
  _ value: JSONValue?,
  variables: JSONObject,
  fieldName: String
) throws -> [String]? {
  guard let values = try memoryFileStringArray(value, fieldName: fieldName) else {
    return nil
  }
  return values.map { renderPromptTemplate($0, variables: variables) }.filter { !$0.isEmpty }
}

private func renderedMemoryFileString(_ value: JSONValue?, variables: JSONObject) -> String? {
  guard let template = nonEmptyString(value) else {
    return nil
  }
  let rendered = renderPromptTemplate(template, variables: variables)
  return rendered.isEmpty ? nil : rendered
}

private func memoryFileStringArray(_ value: JSONValue?, fieldName: String) throws -> [String]? {
  guard let value else {
    return nil
  }
  guard case let .array(values) = value else {
    throw AdapterExecutionError(.policyBlocked, "\(fieldName) must be an array of non-empty strings")
  }
  return try values.enumerated().map { index, value in
    guard let string = nonEmptyString(value) else {
      throw AdapterExecutionError(.policyBlocked, "\(fieldName)[\(index)] must be a non-empty string")
    }
    return string
  }
}

private func memoryFileInt64(_ value: JSONValue?, fieldName: String) throws -> Int64? {
  guard let value else {
    return nil
  }
  guard case let .number(number) = value, let id = Int64(exactly: number), id > 0 else {
    throw AdapterExecutionError(.policyBlocked, "\(fieldName) must be a positive integer")
  }
  return id
}
