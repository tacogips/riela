import Foundation
import RielaCore

extension BuiltinWorkflowAddonResolver {
  func executeAppleNotesCrud(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    let operation = try AppleNotesCrudOperation(addonName: input.addon.name)
    let engine = AppleNotesCrudEngine(
      environment: environment,
      currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    )
    return try engine.execute(operation, input: input, context: context)
  }
}

private enum AppleNotesCrudOperation: String {
  case get = "riela/apple-note-get"
  case create = "riela/apple-note-create"
  case updateBody = "riela/apple-note-update-body"
  case delete = "riela/apple-note-delete"
  case move = "riela/apple-note-move"

  init(addonName: String) throws {
    guard let operation = Self(rawValue: addonName) else {
      throw AdapterExecutionError(.providerError, "missing Apple Notes CRUD add-on resolver for '\(addonName)'")
    }
    self = operation
  }
}

private struct AppleNotesCrudEngine {
  var environment: [String: String]
  var currentDirectory: URL

  func execute(
    _ operation: AppleNotesCrudOperation,
    input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    guard input.addon.env?.isEmpty != false else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) does not support addon.env")
    }

    let config = input.addon.config ?? [:]
    let variables = addonVariables(for: input)
    let resolvedBinary = try AppleGatewayBinaryResolver(
      addonName: input.addon.name,
      config: config,
      environment: environment
    ).resolvedBinary()
    let runner = AppleGatewayProcessRunner(runtimeEnvironment: environment)
    let request = try graphQLRequest(operation: operation, input: input, config: config, variables: variables)
    let processOutput = try runner.run(
      executablePath: resolvedBinary.path,
      arguments: ["graphql", "--query", request.document, "--variables", request.variables.compactJSONString()],
      deadline: context.deadline
    )
    let envelope = try AppleGatewayGraphQLEnvelope(stdout: processOutput.stdout, addonName: input.addon.name)
    if !envelope.errors.isEmpty {
      throw AdapterExecutionError(
        .providerError,
        "\(input.addon.name) GraphQL errors: \(appleGatewayCompactText(envelope.errors.joined(separator: "; ")))"
      )
    }

    switch operation {
    case .get:
      return try getOutput(
        input: input,
        config: config,
        resolvedBinary: resolvedBinary,
        runner: runner,
        envelope: envelope,
        context: context
      )
    case .create:
      let note = try envelope.mutationField("createNote", addonName: input.addon.name)
      return operationOutput(
        input: input,
        resolvedBinary: resolvedBinary,
        envelope: envelope,
        appleNote: note,
        flagName: "created",
        flagValue: true,
        when: ["always": true, "created": true]
      )
    case .updateBody:
      let note = try envelope.mutationField("updateNoteBody", addonName: input.addon.name)
      return operationOutput(
        input: input,
        resolvedBinary: resolvedBinary,
        envelope: envelope,
        appleNote: note,
        flagName: "updated",
        flagValue: true,
        when: ["always": true, "updated": true]
      )
    case .delete:
      let deleteResult = try envelope.mutationField("deleteNote", addonName: input.addon.name)
      let deleted = boolValue(deleteResult["success"]) == true
      var payload = commonPayload(input: input, resolvedBinary: resolvedBinary, envelope: envelope)
      payload["deleteResult"] = .object(deleteResult)
      payload["deleted"] = .bool(deleted)
      return output(input: input, when: ["always": true, "deleted": deleted], payload: payload)
    case .move:
      let note = try envelope.mutationField("moveNote", addonName: input.addon.name)
      return operationOutput(
        input: input,
        resolvedBinary: resolvedBinary,
        envelope: envelope,
        appleNote: note,
        flagName: "moved",
        flagValue: true,
        when: ["always": true, "moved": true]
      )
    }
  }

  private func graphQLRequest(
    operation: AppleNotesCrudOperation,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    variables: JSONObject
  ) throws -> AppleNotesGraphQLRequest {
    switch operation {
    case .get:
      let noteId = try requiredString("noteId", input: input, config: config, variables: variables)
      let includePlaintext = try bool("includePlaintext", config: config, defaultValue: true)
      let includeBodyHtml = try bool("includeBodyHtml", config: config, defaultValue: false)
      let includeBodyFile = try bool("includeBodyFile", config: config, defaultValue: false)
      let includeAttachments = try bool("includeAttachments", config: config, defaultValue: false)
      let materializeBody = try bool("materializeBody", config: config, defaultValue: false)
      let flags = AppleNoteGetSelectionFlags(
        includePlaintext: includePlaintext,
        includeBodyHtml: includeBodyHtml,
        includeBodyFile: includeBodyFile || materializeBody,
        includeAttachments: includeAttachments
      )
      return AppleNotesGraphQLRequest(
        document: getDocument(flags: flags),
        variables: .object(["noteId": .string(noteId)])
      )
    case .create:
      let title = try requiredString("title", input: input, config: config, variables: variables)
      var createInput: JSONObject = ["title": .string(title)]
      appendOptionalString("accountId", to: &createInput, input: input, config: config, variables: variables)
      appendOptionalString("folderId", to: &createInput, input: input, config: config, variables: variables)
      let hasBody = appendBodyFields(to: &createInput, input: input, config: config, variables: variables)
      guard hasBody else {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) requires bodyHtml or bodyText")
      }
      return AppleNotesGraphQLRequest(document: Self.createDocument, variables: .object(["input": .object(createInput)]))
    case .updateBody:
      let noteId = try requiredString("noteId", input: input, config: config, variables: variables)
      let mode = try updateMode(input: input, config: config, variables: variables)
      var updateInput: JSONObject = [
        "noteId": .string(noteId),
        "mode": .string(mode)
      ]
      let hasBody = appendBodyFields(to: &updateInput, input: input, config: config, variables: variables)
      guard hasBody else {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) requires bodyHtml or bodyText")
      }
      return AppleNotesGraphQLRequest(document: Self.updateBodyDocument, variables: .object(["input": .object(updateInput)]))
    case .delete:
      let noteId = try requiredString("noteId", input: input, config: config, variables: variables)
      return AppleNotesGraphQLRequest(document: Self.deleteDocument, variables: .object(["noteId": .string(noteId)]))
    case .move:
      let noteId = try requiredString("noteId", input: input, config: config, variables: variables)
      let folderId = try requiredString("folderId", input: input, config: config, variables: variables)
      return AppleNotesGraphQLRequest(
        document: Self.moveDocument,
        variables: .object(["noteId": .string(noteId), "folderId": .string(folderId)])
      )
    }
  }

  private func getOutput(
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    resolvedBinary: AppleGatewayResolvedBinary,
    runner: AppleGatewayProcessRunner,
    envelope: AppleGatewayGraphQLEnvelope,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    var payload = commonPayload(input: input, resolvedBinary: resolvedBinary, envelope: envelope)
    guard case var .object(note)? = envelope.data["note"] else {
      if envelope.data["note"] == nil || envelope.data["note"] == .null {
        payload["appleNote"] = envelope.data["note"] ?? .null
        return output(input: input, when: ["always": true, "has_note": false], payload: payload)
      }
      throw AdapterExecutionError(.invalidOutput, "\(input.addon.name) GraphQL data.note must be an object or null")
    }
    if try bool("materializeBody", config: config, defaultValue: false),
      let bodyFile = objectValue(note["bodyFile"]),
      let downloadKey = nonEmptyString(bodyFile["downloadKey"]) {
      let outputRoot = try downloadRoot(input: input, config: config)
      let downloader = AppleGatewayFileDownloader(
        runner: runner,
        resolvedBinary: resolvedBinary,
        currentDirectory: currentDirectory
      )
      let downloaded = try downloader.download(keys: [downloadKey], outputRoot: outputRoot, deadline: context.deadline)
      if let localPath = downloaded[downloadKey] {
        var updatedBodyFile = bodyFile
        updatedBodyFile["localPath"] = .string(localPath)
        note["bodyFile"] = .object(updatedBodyFile)
        var body = objectValue(note["body"]) ?? [:]
        body["materializedPath"] = .string(localPath)
        note["body"] = .object(body)
      }
    }
    payload["appleNote"] = .object(note)
    return output(input: input, when: ["always": true, "has_note": true], payload: payload)
  }

  private func operationOutput(
    input: WorkflowAddonExecutionInput,
    resolvedBinary: AppleGatewayResolvedBinary,
    envelope: AppleGatewayGraphQLEnvelope,
    appleNote: JSONObject,
    flagName: String,
    flagValue: Bool,
    when: [String: Bool]
  ) -> AdapterExecutionOutput {
    var payload = commonPayload(input: input, resolvedBinary: resolvedBinary, envelope: envelope)
    payload["appleNote"] = .object(appleNote)
    payload[flagName] = .bool(flagValue)
    return output(input: input, when: when, payload: payload)
  }

  private func output(input: WorkflowAddonExecutionInput, when: [String: Bool], payload: JSONObject) -> AdapterExecutionOutput {
    AdapterExecutionOutput(
      provider: "apple-gateway",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: when,
      payload: payload
    )
  }

  private func commonPayload(
    input: WorkflowAddonExecutionInput,
    resolvedBinary: AppleGatewayResolvedBinary,
    envelope: AppleGatewayGraphQLEnvelope
  ) -> JSONObject {
    let requestId = envelope.requestId ?? ""
    return [
      "status": .string("ok"),
      "addon": .string(input.addon.name),
      "stepId": .string(input.stepId),
      "appleGateway": .object([
        "binary": .object([
          "path": .string(resolvedBinary.path),
          "source": .string(resolvedBinary.source.rawValue)
        ]),
        "requestId": .string(requestId),
        "rawData": .object(envelope.data)
      ])
    ]
  }

  private func requiredString(
    _ key: String,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    variables: JSONObject
  ) throws -> String {
    guard let value = nonBlankString(key, config: config, variables: variables) else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) \(key) is required")
    }
    return value
  }

  private func appendOptionalString(
    _ key: String,
    to object: inout JSONObject,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    variables: JSONObject
  ) {
    if let value = string(key, config: config, variables: variables) {
      object[key] = .string(value)
    }
  }

  private func appendBodyFields(
    to object: inout JSONObject,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    variables: JSONObject
  ) -> Bool {
    var hasBody = false
    if let bodyHtml = nonBlankString("bodyHtml", config: config, variables: variables) {
      object["bodyHtml"] = .string(bodyHtml)
      hasBody = true
    }
    if let bodyText = nonBlankString("bodyText", config: config, variables: variables) {
      object["bodyText"] = .string(bodyText)
      hasBody = true
    }
    return hasBody
  }

  private func nonBlankString(_ key: String, config: JSONObject, variables: JSONObject) -> String? {
    guard let value = string(key, config: config, variables: variables) else {
      return nil
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
  }

  private func string(_ key: String, config: JSONObject, variables: JSONObject) -> String? {
    if let value = nonEmptyString(variables[key]) {
      return value
    }
    if let template = nonEmptyString(config[key]) {
      let rendered = renderPromptTemplate(template, variables: variables).trimmingCharacters(in: .whitespacesAndNewlines)
      return rendered.isEmpty ? nil : rendered
    }
    return nil
  }

  private func bool(_ key: String, config: JSONObject, defaultValue: Bool) throws -> Bool {
    if let value = boolValue(config[key]) {
      return value
    }
    guard config[key] == nil else {
      throw AdapterExecutionError(.policyBlocked, "Apple Notes config.\(key) must be a boolean")
    }
    return defaultValue
  }

  private func updateMode(input: WorkflowAddonExecutionInput, config: JSONObject, variables: JSONObject) throws -> String {
    let raw = string("mode", config: config, variables: variables) ?? "REPLACE"
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard normalized == "REPLACE" || normalized == "APPEND" else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) mode must be REPLACE or APPEND")
    }
    return normalized
  }

  private func downloadRoot(input: WorkflowAddonExecutionInput, config: JSONObject) throws -> String {
    if let configured = nonEmptyString(config["downloadDir"])?.trimmingCharacters(in: .whitespacesAndNewlines),
      !configured.isEmpty {
      return configured
    }
    if let environmentRoot = environmentValue("RIELA_APPLE_NOTES_DOWNLOAD_ROOT", environment: environment) {
      return environmentRoot
    }
    throw AdapterExecutionError(
      .policyBlocked,
      "\(input.addon.name) materializeBody requires config.downloadDir or RIELA_APPLE_NOTES_DOWNLOAD_ROOT"
    )
  }

  private func getDocument(flags: AppleNoteGetSelectionFlags) -> String {
    var fields = [
      "    id",
      "    accountId",
      "    folderId",
      "    name",
      "    snippet",
      "    isPasswordProtected",
      "    isShared",
      "    creationDate",
      "    modificationDate"
    ]
    if flags.includePlaintext {
      fields.append("    plaintext")
    }
    if flags.includeBodyHtml {
      fields.append("    bodyHtml")
    }
    if flags.includeBodyFile {
      fields.append("    bodyFile {")
      fields.append("      downloadKey")
      fields.append("      kind")
      fields.append("      byteSize")
      fields.append("    }")
    }
    if flags.includeAttachments {
      fields.append("    attachments {")
      fields.append("      id")
      fields.append("      name")
      fields.append("      contentIdentifier")
      fields.append("      downloadKey")
      fields.append("    }")
    }
    return """
    query RielaAppleNoteGet($noteId: ID!) {
      note(noteId: $noteId) {
    \(fields.joined(separator: "\n"))
      }
    }
    """
  }

  private static let createDocument = """
  mutation RielaAppleNoteCreate($input: CreateNoteInput!) {
    createNote(input: $input) {
      id
      accountId
      folderId
      name
      snippet
      creationDate
      modificationDate
    }
  }
  """

  private static let updateBodyDocument = """
  mutation RielaAppleNoteUpdateBody($input: UpdateNoteBodyInput!) {
    updateNoteBody(input: $input) {
      id
      name
      snippet
      modificationDate
    }
  }
  """

  private static let deleteDocument = """
  mutation RielaAppleNoteDelete($noteId: ID!) {
    deleteNote(noteId: $noteId) {
      success
    }
  }
  """

  private static let moveDocument = """
  mutation RielaAppleNoteMove($noteId: ID!, $folderId: ID!) {
    moveNote(noteId: $noteId, folderId: $folderId) {
      id
      folderId
      name
      modificationDate
    }
  }
  """
}

private struct AppleNotesGraphQLRequest {
  var document: String
  var variables: JSONValue
}

private struct AppleNoteGetSelectionFlags {
  var includePlaintext: Bool
  var includeBodyHtml: Bool
  var includeBodyFile: Bool
  var includeAttachments: Bool
}
