import Foundation
import RielaCore

extension BuiltinWorkflowAddonResolver {
  func executeAppleNotesList(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    guard input.addon.env?.isEmpty != false else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) does not support addon.env")
    }

    let listContext = try AppleNotesListContext(input: input, environment: environment)
    let query = try listContext.graphQLQuery()
    let resolvedBinary = try AppleGatewayBinaryResolver(
      addonName: input.addon.name,
      config: input.addon.config ?? [:],
      environment: environment
    ).resolvedBinary()
    let processOutput = try AppleGatewayProcessRunner(runtimeEnvironment: environment).run(
      executablePath: resolvedBinary.path,
      arguments: ["graphql", "--query", query],
      deadline: context.deadline
    )
    let envelope = try AppleGatewayGraphQLEnvelope(stdout: processOutput.stdout, addonName: input.addon.name)
    if !envelope.errors.isEmpty {
      throw AdapterExecutionError(
        .providerError,
        "\(input.addon.name) GraphQL errors: \(appleGatewayCompactText(envelope.errors.joined(separator: "; ")))"
      )
    }
    let data = envelope.data
    let notesPayload = try AppleGatewayNotesPayload(data: data, addonName: input.addon.name)
    let requestId = envelope.requestId ?? ""
    let appleNotes: JSONObject = [
      "accounts": .array(notesPayload.accounts),
      "folders": .array(notesPayload.folders),
      "notes": .array(notesPayload.notes.map(JSONValue.object)),
      "pageInfo": .object(notesPayload.pageInfo),
      "totalCount": notesPayload.totalCount,
      "requestId": .string(requestId)
    ]
    let payload: JSONObject = [
      "status": .string("ok"),
      "addon": .string(input.addon.name),
      "stepId": .string(input.stepId),
      "appleNotes": .object(appleNotes),
      "noteCount": .number(Double(notesPayload.notes.count)),
      "replyText": .string("Listed \(notesPayload.notes.count) Apple Notes."),
      "appleGateway": .object([
        "binary": .object([
          "path": .string(resolvedBinary.path),
          "source": .string(resolvedBinary.source.rawValue)
        ]),
        "requestId": .string(requestId),
        "rawData": .object(data)
      ])
    ]

    return AdapterExecutionOutput(
      provider: "apple-gateway",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: ["always": true, "has_notes": !notesPayload.notes.isEmpty],
      payload: payload
    )
  }
}

private struct AppleNotesListContext {
  private static let defaultFirst = 25
  private static let maxFirst = 100

  var input: WorkflowAddonExecutionInput
  var config: JSONObject
  var variables: JSONObject

  init(input: WorkflowAddonExecutionInput, environment: [String: String]) throws {
    self.input = input
    self.config = input.addon.config ?? [:]
    self.variables = addonVariables(for: input)
    _ = try first()
    _ = try bool("includePlaintext", defaultValue: false)
    _ = try bool("includeBodyHtml", defaultValue: false)
    _ = try bool("includeBodyFiles", defaultValue: false)
    _ = try bool("includeAttachments", defaultValue: false)
  }

  func graphQLQuery() throws -> String {
    let noteFields = noteSelectionFields()
    return """
    query RielaAppleNotesList {
      noteAccounts {
        id
        name
        isDefault
      }
      noteFolders {
        id
        accountId
        name
        parentFolderId
        noteCount
      }
      notes(input: {\(try notesInputLiteral())}) {
        totalCount
        pageInfo {
          hasNextPage
          endCursor
        }
        edges {
          cursor
          node {
    \(noteFields)
          }
        }
      }
    }
    """
  }

  private func notesInputLiteral() throws -> String {
    var fields = ["first: \(try first())"]
    appendStringField("accountId", to: &fields)
    appendStringField("folderId", to: &fields)
    appendStringField("query", to: &fields)
    appendStringField("modifiedAfter", to: &fields)
    appendStringField("modifiedBefore", to: &fields)
    appendStringField("after", to: &fields)
    return fields.joined(separator: ", ")
  }

  private func appendStringField(_ key: String, to fields: inout [String]) {
    guard let value = string(key) else {
      return
    }
    fields.append("\(key): \(appleGatewayGraphQLString(value))")
  }

  private func noteSelectionFields() -> String {
    var fields = [
      "            id",
      "            accountId",
      "            folderId",
      "            name",
      "            snippet",
      "            isPasswordProtected",
      "            isShared",
      "            creationDate",
      "            modificationDate"
    ]
    if (try? bool("includePlaintext", defaultValue: false)) == true {
      fields.append("            plaintext")
    }
    if (try? bool("includeBodyHtml", defaultValue: false)) == true {
      fields.append("            bodyHtml")
    }
    if (try? bool("includeBodyFiles", defaultValue: false)) == true {
      fields.append("            bodyFile {")
      fields.append("              downloadKey")
      fields.append("              kind")
      fields.append("              byteSize")
      fields.append("            }")
    }
    if (try? bool("includeAttachments", defaultValue: false)) == true {
      fields.append("            attachments {")
      fields.append("              id")
      fields.append("              name")
      fields.append("              contentIdentifier")
      fields.append("              downloadKey")
      fields.append("            }")
    }
    return fields.joined(separator: "\n")
  }

  private func string(_ key: String) -> String? {
    if let template = nonEmptyString(config[key]) {
      let rendered = renderPromptTemplate(template, variables: variables).trimmingCharacters(in: .whitespacesAndNewlines)
      return rendered.isEmpty ? nil : rendered
    }
    guard let value = nonEmptyString(variables[key])?.trimmingCharacters(in: .whitespacesAndNewlines) else {
      return nil
    }
    return value.isEmpty ? nil : value
  }

  private func first() throws -> Int {
    let raw = intValue(config["first"]) ?? intValue(variables["first"]) ?? Self.defaultFirst
    guard raw > 0 && raw <= Self.maxFirst else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) first must be between 1 and \(Self.maxFirst)")
    }
    return raw
  }

  private func bool(_ key: String, defaultValue: Bool) throws -> Bool {
    if let value = boolValue(config[key]) ?? boolValue(variables[key]) {
      return value
    }
    guard config[key] != nil || variables[key] != nil else {
      return defaultValue
    }
    throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) must be a boolean")
  }
}

private struct AppleGatewayNotesPayload {
  var accounts: [JSONValue]
  var folders: [JSONValue]
  var notes: [JSONObject]
  var pageInfo: JSONObject
  var totalCount: JSONValue

  init(data: JSONObject, addonName: String) throws {
    self.accounts = try appleGatewayRequiredArray(
      data["noteAccounts"],
      field: "\(addonName) GraphQL data.noteAccounts"
    )
    self.folders = try appleGatewayRequiredArray(
      data["noteFolders"],
      field: "\(addonName) GraphQL data.noteFolders"
    )
    let notesConnection = try appleGatewayRequiredObject(
      data["notes"],
      field: "\(addonName) GraphQL data.notes"
    )
    let edges = try appleGatewayRequiredArray(
      notesConnection["edges"],
      field: "\(addonName) GraphQL data.notes.edges"
    )
    self.notes = try edges.enumerated().map { index, edge in
      try appleGatewayNote(fromEdge: edge, index: index, addonName: addonName)
    }
    self.pageInfo = try appleGatewayRequiredObject(
      notesConnection["pageInfo"],
      field: "\(addonName) GraphQL data.notes.pageInfo"
    )
    self.totalCount = try appleGatewayRequiredNumber(
      notesConnection["totalCount"],
      field: "\(addonName) GraphQL data.notes.totalCount"
    )
  }
}

private func appleGatewayNote(fromEdge value: JSONValue, index: Int, addonName: String) throws -> JSONObject {
  guard case let .object(edge) = value else {
    throw AdapterExecutionError(
      .invalidOutput,
      "\(addonName) GraphQL data.notes.edges[\(index)] must be an object"
    )
  }
  guard case var .object(node)? = edge["node"] else {
    throw AdapterExecutionError(
      .invalidOutput,
      "\(addonName) GraphQL data.notes.edges[\(index)].node must be an object"
    )
  }
  if let cursor = nonEmptyString(edge["cursor"]) {
    node["cursor"] = .string(cursor)
  }
  return node
}
