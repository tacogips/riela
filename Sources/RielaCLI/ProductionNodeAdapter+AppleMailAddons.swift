import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension BuiltinWorkflowAddonResolver {
  func executeAppleMailAddon(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    try AppleMailAddonEngine(
      environment: environment,
      currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ).execute(input, context: context)
  }
}

private struct AppleMailAddonEngine {
  private static let fdaGuidance =
    "Grant Full Disk Access in System Settings > Privacy & Security > Full Disk Access, then rerun apple-gateway permissions status --json."
  private static let blockedPermissionStates = Set(["DENIED", "NOT_DETERMINED", "UNKNOWN"])
  private static let defaultFirst = 25
  private static let maxFirst = 100
  private static let defaultMaxDownloadBytes = 25 * 1_024 * 1_024
  private static let ownerOnlyDirectoryPermissions = 0o700
  private static let groupOrOtherPermissionBits = 0o077
  private static let allowedSystemSymlinkComponents = ["/tmp", "/var"]

  var environment: [String: String]
  var currentDirectory: URL

  func execute(
    _ input: WorkflowAddonExecutionInput,
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
    let query = try graphQLQuery(for: input, config: config, variables: variables)
    let processOutput: AppleGatewayProcessOutput
    do {
      processOutput = try runner.run(
        executablePath: resolvedBinary.path,
        arguments: ["graphql", "--query", query],
        deadline: context.deadline
      )
    } catch let error as AdapterExecutionError where isFullDiskAccessText(error.message) {
      throw fullDiskAccessError(input.addon.name, detail: error.message)
    }
    let envelope = try AppleGatewayGraphQLEnvelope(stdout: processOutput.stdout, addonName: input.addon.name)
    try validateEnvelope(envelope, addonName: input.addon.name)
    switch input.addon.name {
    case "riela/apple-mail-list":
      return try listOutput(input: input, resolvedBinary: resolvedBinary, envelope: envelope)
    case "riela/apple-mail-message":
      return try messageOutput(
        input: input,
        config: config,
        variables: variables,
        resolvedBinary: resolvedBinary,
        runner: runner,
        envelope: envelope,
        context: context
      )
    default:
      throw AdapterExecutionError(.providerError, "missing Apple Mail add-on resolver for '\(input.addon.name)'")
    }
  }

  private func graphQLQuery(
    for input: WorkflowAddonExecutionInput,
    config: JSONObject,
    variables: JSONObject
  ) throws -> String {
    switch input.addon.name {
    case "riela/apple-mail-list":
      return try listQuery(config: config, variables: variables, addonName: input.addon.name)
    case "riela/apple-mail-message":
      let messageId = try requiredString("messageId", input: input, config: config, variables: variables)
      return """
      query RielaAppleMailMessage {
        permissions { mailFullDiskAccess }
        mailMessage(messageId: \(appleGatewayGraphQLString(messageId))) {
      \(Self.mailMessageSelection)
        }
      }
      """
    default:
      throw AdapterExecutionError(.providerError, "missing Apple Mail add-on resolver for '\(input.addon.name)'")
    }
  }

  private func listQuery(config: JSONObject, variables: JSONObject, addonName: String) throws -> String {
    let inputLiteral = try mailSearchInputLiteral(config: config, variables: variables, addonName: addonName)
    let mailboxArgument = optionalString("accountId", config: config, variables: variables)
      .map { "(accountId: \(appleGatewayGraphQLString($0)))" } ?? ""
    return """
    query RielaAppleMailList {
      permissions { mailFullDiskAccess }
      mailAccounts { id name kind }
      mailboxes\(mailboxArgument) { id accountId name path totalCount unreadCount }
      mailMessages(input: {\(inputLiteral)}) {
        totalCount
        pageInfo { hasNextPage endCursor }
        edges {
          cursor
          node {
    \(Self.mailMessageSelection)
          }
        }
      }
    }
    """
  }

  private static let mailMessageSelection = """
            id
            mailboxId
            accountId
            messageId
            subject
            snippet
            from { raw name email }
            to { raw name email }
            cc { raw name email }
            dateSent
            dateReceived
            isRead
            isFlagged
            hasAttachments
            files {
              bodyText { downloadKey kind filename mimeType byteSize }
              bodyHtml { downloadKey kind filename mimeType byteSize }
              rawSource { downloadKey kind filename mimeType byteSize }
              attachments { downloadKey kind filename mimeType byteSize }
            }
    """

  private func mailSearchInputLiteral(
    config: JSONObject,
    variables: JSONObject,
    addonName: String
  ) throws -> String {
    var fields = ["first: \(try first(config: config, variables: variables, addonName: addonName))"]
    for key in ["accountId", "mailboxId", "query", "from", "to", "subject", "receivedAfter", "receivedBefore", "after"] {
      if let value = optionalString(key, config: config, variables: variables) {
        fields.append("\(key): \(appleGatewayGraphQLString(value))")
      }
    }
    for key in ["unreadOnly", "flaggedOnly"] {
      if let value = try optionalBool(key, config: config, variables: variables, addonName: addonName) {
        fields.append("\(key): \(value ? "true" : "false")")
      }
    }
    return fields.joined(separator: ", ")
  }

  private func listOutput(
    input: WorkflowAddonExecutionInput,
    resolvedBinary: AppleGatewayResolvedBinary,
    envelope: AppleGatewayGraphQLEnvelope
  ) throws -> AdapterExecutionOutput {
    let accounts = try appleGatewayRequiredArray(envelope.data["mailAccounts"], field: "\(input.addon.name) GraphQL data.mailAccounts")
    let mailboxes = try appleGatewayRequiredArray(envelope.data["mailboxes"], field: "\(input.addon.name) GraphQL data.mailboxes")
    let connection = try appleGatewayRequiredObject(envelope.data["mailMessages"], field: "\(input.addon.name) GraphQL data.mailMessages")
    let edges = try appleGatewayRequiredArray(connection["edges"], field: "\(input.addon.name) GraphQL data.mailMessages.edges")
    let messages = try edges.enumerated().map { index, edge in
      try mailMessage(fromEdge: edge, index: index, addonName: input.addon.name)
    }
    let pageInfo = try appleGatewayRequiredObject(connection["pageInfo"], field: "\(input.addon.name) GraphQL data.mailMessages.pageInfo")
    let totalCount = try appleGatewayRequiredNumber(connection["totalCount"], field: "\(input.addon.name) GraphQL data.mailMessages.totalCount")
    let requestId = envelope.requestId ?? ""
    let permissions = objectValue(envelope.data["permissions"]) ?? [:]
    let appleMail: JSONObject = [
      "accounts": .array(accounts),
      "mailboxes": .array(mailboxes),
      "messages": .array(messages.map(JSONValue.object)),
      "pageInfo": .object(pageInfo),
      "totalCount": totalCount,
      "requestId": .string(requestId),
      "permissions": .object(permissions)
    ]
    return output(
      input: input,
      resolvedBinary: resolvedBinary,
      envelope: envelope,
      appleMail: appleMail,
      when: ["always": true, "has_messages": !messages.isEmpty],
      replyText: "Listed \(messages.count) Apple Mail messages.",
      extraPayload: ["messageCount": .integer(Int64(messages.count))]
    )
  }

  private func messageOutput(
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    variables: JSONObject,
    resolvedBinary: AppleGatewayResolvedBinary,
    runner: AppleGatewayProcessRunner,
    envelope: AppleGatewayGraphQLEnvelope,
    context: AdapterExecutionContext
  ) throws -> AdapterExecutionOutput {
    guard let messageValue = envelope.data["mailMessage"] else {
      throw AdapterExecutionError(.invalidOutput, "\(input.addon.name) GraphQL data.mailMessage is missing")
    }
    let requestId = envelope.requestId ?? ""
    let permissions = objectValue(envelope.data["permissions"]) ?? [:]
    guard messageValue != .null else {
      return output(
        input: input,
        resolvedBinary: resolvedBinary,
        envelope: envelope,
        appleMail: [
          "message": .null,
          "found": .bool(false),
          "requestId": .string(requestId),
          "permissions": .object(permissions)
        ],
        when: ["always": true, "found": false],
        replyText: "Apple Mail message was not found."
      )
    }
    guard case var .object(message) = messageValue else {
      throw AdapterExecutionError(.invalidOutput, "\(input.addon.name) GraphQL data.mailMessage must be an object or null")
    }
    let materialization = try materializeFiles(
      message: message,
      input: input,
      config: config,
      variables: variables,
      resolvedBinary: resolvedBinary,
      runner: runner,
      context: context
    )
    message["materialized"] = .array(materialization.materialized.map(JSONValue.object))
    message["skippedDownloads"] = .array(materialization.skipped.map(JSONValue.object))
    let appleMail: JSONObject = [
      "message": .object(message),
      "found": .bool(true),
      "requestId": .string(requestId),
      "permissions": .object(permissions),
      "downloadRoot": .string(materialization.downloadRoot),
      "materialized": .array(materialization.materialized.map(JSONValue.object)),
      "skippedDownloads": .array(materialization.skipped.map(JSONValue.object))
    ]
    return output(
      input: input,
      resolvedBinary: resolvedBinary,
      envelope: envelope,
      appleMail: appleMail,
      when: ["always": true, "found": true],
      replyText: "Fetched Apple Mail message."
    )
  }

  private func output(
    input: WorkflowAddonExecutionInput,
    resolvedBinary: AppleGatewayResolvedBinary,
    envelope: AppleGatewayGraphQLEnvelope,
    appleMail: JSONObject,
    when: [String: Bool],
    replyText: String,
    extraPayload: JSONObject = [:]
  ) -> AdapterExecutionOutput {
    let requestId = envelope.requestId ?? ""
    var payload: JSONObject = [
      "status": .string("ok"),
      "addon": .string(input.addon.name),
      "stepId": .string(input.stepId),
      "appleMail": .object(appleMail),
      "replyText": .string(replyText),
      "appleGateway": .object([
        "binary": .object([
          "path": .string(resolvedBinary.path),
          "source": .string(resolvedBinary.source.rawValue)
        ]),
        "requestId": .string(requestId),
        "rawData": .object(envelope.data)
      ])
    ]
    for (key, value) in extraPayload {
      payload[key] = value
    }
    return AdapterExecutionOutput(
      provider: "apple-gateway",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: when,
      payload: payload
    )
  }

  private func validateEnvelope(_ envelope: AppleGatewayGraphQLEnvelope, addonName: String) throws {
    if !envelope.errors.isEmpty {
      let detail = appleGatewayCompactText(envelope.errors.joined(separator: "; "))
      if isFullDiskAccessText(detail) {
        throw fullDiskAccessError(addonName, detail: detail)
      }
      throw AdapterExecutionError(.providerError, "\(addonName) GraphQL errors: \(detail)")
    }
    if let permission = nonEmptyString(objectValue(envelope.data["permissions"])?["mailFullDiskAccess"]) {
      let normalized = permission.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      if Self.blockedPermissionStates.contains(normalized) {
        throw fullDiskAccessError(addonName, detail: "mailFullDiskAccess=\(permission)")
      }
    }
  }

  private func materializeFiles(
    message: JSONObject,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    variables: JSONObject,
    resolvedBinary: AppleGatewayResolvedBinary,
    runner: AppleGatewayProcessRunner,
    context: AdapterExecutionContext
  ) throws -> AppleMailMaterializationResult {
    let descriptors = try selectedDescriptors(
      message: message,
      config: config,
      addonName: input.addon.name
    )
    let downloadRoot = try validatedDownloadRoot(input: input, config: config, variables: variables)
    let maxBytes = try maxDownloadBytes(config: config, addonName: input.addon.name)
    var materialized: [JSONObject] = []
    var skipped: [JSONObject] = []
    var usedNames: [String: Int] = [:]
    for (index, descriptor) in descriptors.enumerated() {
      guard let downloadKey = nonEmptyString(descriptor.value["downloadKey"]) else {
        skipped.append(skipEntry(descriptor, reason: "missing_download_key"))
        continue
      }
      if let byteSize = intValue(descriptor.value["byteSize"]), byteSize > maxBytes {
        skipped.append(skipEntry(descriptor, reason: "exceeds_maxDownloadBytes"))
        continue
      }
      let filename = uniqueFilename(
        preferred: nonEmptyString(descriptor.value["filename"]),
        fallback: "\(descriptor.kind)-\(index + 1)",
        usedNames: &usedNames
      )
      let destination = downloadRoot.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
      guard destination.path.hasPrefix(downloadRoot.path + "/") else {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) sanitized download filename escaped download root")
      }
      let data: AppleGatewayProcessDataOutput
      do {
        data = try runner.runData(
          executablePath: resolvedBinary.path,
          arguments: ["file", "download", "--key", downloadKey],
          deadline: context.deadline
        )
      } catch let error as AdapterExecutionError where isFullDiskAccessText(error.message) {
        throw fullDiskAccessError(input.addon.name, detail: error.message)
      }
      guard data.stdoutData.count <= maxBytes else {
        skipped.append(skipEntry(
          descriptor,
          reason: "exceeds_maxDownloadBytes",
          actualByteSize: data.stdoutData.count
        ))
        continue
      }
      do {
        try data.stdoutData.write(to: destination, options: .atomic)
      } catch {
        throw AdapterExecutionError(.providerError, "\(input.addon.name) could not write downloaded file: \(error.localizedDescription)")
      }
      var entry = descriptor.value
      entry["kind"] = .string(descriptor.kind)
      entry["filename"] = .string(filename)
      entry["downloadKey"] = .string(downloadKey)
      entry["localPath"] = .string(destination.path)
      entry["materializedByteSize"] = .integer(Int64(data.stdoutData.count))
      materialized.append(entry)
    }
    return AppleMailMaterializationResult(
      downloadRoot: downloadRoot.path,
      materialized: materialized,
      skipped: skipped
    )
  }

  private func selectedDescriptors(
    message: JSONObject,
    config: JSONObject,
    addonName: String
  ) throws -> [AppleMailFileDescriptor] {
    let includeBodyText = try materializationFlag(
      "materializeBodyText",
      defaultValue: true,
      config: config,
      addonName: addonName
    )
    let includeBodyHtml = try materializationFlag(
      "materializeBodyHtml",
      defaultValue: false,
      config: config,
      addonName: addonName
    )
    let includeRawSource = try materializationFlag(
      "materializeRawSource",
      defaultValue: false,
      config: config,
      addonName: addonName
    )
    let includeAttachments = try materializationFlag(
      "materializeAttachments",
      defaultValue: false,
      config: config,
      addonName: addonName
    )
    let requiresFiles = includeBodyText || includeBodyHtml || includeRawSource || includeAttachments
    guard let files = try mailFilesObject(message["files"], requiresFiles: requiresFiles, addonName: addonName) else {
      return []
    }
    var descriptors: [AppleMailFileDescriptor] = []
    if includeBodyText,
      let descriptor = try optionalBodyDescriptor(files["bodyText"], field: "bodyText", addonName: addonName) {
      descriptors.append(AppleMailFileDescriptor(kind: "bodyText", value: descriptor))
    }
    if includeBodyHtml,
      let descriptor = try optionalBodyDescriptor(files["bodyHtml"], field: "bodyHtml", addonName: addonName) {
      descriptors.append(AppleMailFileDescriptor(kind: "bodyHtml", value: descriptor))
    }
    if includeRawSource,
      let descriptor = try optionalBodyDescriptor(files["rawSource"], field: "rawSource", addonName: addonName) {
      descriptors.append(AppleMailFileDescriptor(kind: "rawSource", value: descriptor))
    }
    if includeAttachments {
      let attachments = try attachmentDescriptors(files["attachments"], addonName: addonName)
      descriptors += attachments.map { AppleMailFileDescriptor(kind: "attachment", value: $0) }
    }
    return descriptors
  }

  private func mailFilesObject(
    _ value: JSONValue?,
    requiresFiles: Bool,
    addonName: String
  ) throws -> JSONObject? {
    guard let value else {
      guard !requiresFiles else {
        throw AdapterExecutionError(.invalidOutput, "\(addonName) GraphQL data.mailMessage.files must be an object")
      }
      return nil
    }
    guard case let .object(files) = value else {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) GraphQL data.mailMessage.files must be an object")
    }
    return files
  }

  private func optionalBodyDescriptor(
    _ value: JSONValue?,
    field: String,
    addonName: String
  ) throws -> JSONObject? {
    guard let value, value != .null else {
      return nil
    }
    guard case let .object(descriptor) = value else {
      throw AdapterExecutionError(
        .invalidOutput,
        "\(addonName) GraphQL data.mailMessage.files.\(field) must be an object when non-null"
      )
    }
    return descriptor
  }

  private func attachmentDescriptors(_ value: JSONValue?, addonName: String) throws -> [JSONObject] {
    guard case let .array(attachments)? = value else {
      throw AdapterExecutionError(
        .invalidOutput,
        "\(addonName) GraphQL data.mailMessage.files.attachments must be an array"
      )
    }
    return try attachments.enumerated().map { index, attachment in
      guard case let .object(descriptor) = attachment else {
        throw AdapterExecutionError(
          .invalidOutput,
          "\(addonName) GraphQL data.mailMessage.files.attachments[\(index)] must be an object"
        )
      }
      return descriptor
    }
  }

  private func validatedDownloadRoot(
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    variables: JSONObject
  ) throws -> URL {
    let configured = nonEmptyString(config["downloadDir"])?.trimmingCharacters(in: .whitespacesAndNewlines)
    let env = environmentValue("APPLE_GATEWAY_DOWNLOAD_DIR", environment: environment)
    let basePath = configured?.isEmpty == false ? configured : env
    let rawPath = basePath ?? defaultDownloadRoot(input: input, variables: variables).path
    let url = URL(fileURLWithPath: rawPath, relativeTo: currentDirectory).standardizedFileURL
    try validateNoSymlinkComponents(url, label: "downloadDir")
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: Self.ownerOnlyDirectoryPermissions]
    )
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    try validateOwnerPrivateDirectory(resolved, label: "downloadDir")
    return resolved
  }

  private func defaultDownloadRoot(input: WorkflowAddonExecutionInput, variables: JSONObject) -> URL {
    let messageId = nonEmptyString(variables["messageId"]) ?? "message"
    let safeMessageId = sanitizedFilename(messageId, fallback: "message")
    let tmp = environmentValue("TMPDIR", environment: environment) ?? NSTemporaryDirectory()
    return URL(fileURLWithPath: tmp, isDirectory: true)
      .appendingPathComponent("riela-apple-mail", isDirectory: true)
      .appendingPathComponent(sanitizedFilename(input.workflowId, fallback: "workflow"), isDirectory: true)
      .appendingPathComponent(sanitizedFilename(input.nodeId, fallback: "node"), isDirectory: true)
      .appendingPathComponent(safeMessageId, isDirectory: true)
  }

  private func validateNoSymlinkComponents(_ url: URL, label: String) throws {
    var currentURL = URL(fileURLWithPath: "/", isDirectory: true)
    for component in url.pathComponents.dropFirst() {
      currentURL.appendPathComponent(component, isDirectory: true)
      guard FileManager.default.fileExists(atPath: currentURL.path) else {
        return
      }
      if isSymbolicLink(currentURL), !Self.allowedSystemSymlinkComponents.contains(currentURL.path) {
        throw AdapterExecutionError(.policyBlocked, "\(label) must not contain a symbolic link component: \(url.path)")
      }
    }
  }

  private func validateOwnerPrivateDirectory(_ url: URL, label: String) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let type = attributes[.type] as? FileAttributeType, type == .typeDirectory else {
      throw AdapterExecutionError(.policyBlocked, "\(label) must point to a directory: \(url.path)")
    }
    #if canImport(Darwin) || canImport(Glibc)
    if let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value != getuid() {
      throw AdapterExecutionError(.policyBlocked, "\(label) must be owned by the current user: \(url.path)")
    }
    #endif
    guard let permissions = attributes[.posixPermissions] as? NSNumber,
      permissions.intValue & Self.groupOrOtherPermissionBits == 0
    else {
      throw AdapterExecutionError(.policyBlocked, "\(label) must be owner-private: \(url.path)")
    }
  }

  private func isSymbolicLink(_ url: URL) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
  }

  private func requiredString(
    _ key: String,
    input: WorkflowAddonExecutionInput,
    config: JSONObject,
    variables: JSONObject
  ) throws -> String {
    guard let value = optionalString(key, config: config, variables: variables) else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) requires \(key)")
    }
    return value
  }

  private func optionalString(_ key: String, config: JSONObject, variables: JSONObject) -> String? {
    if let template = nonEmptyString(config[key]) {
      let rendered = renderPromptTemplate(template, variables: variables).trimmingCharacters(in: .whitespacesAndNewlines)
      return rendered.isEmpty ? nil : rendered
    }
    guard let value = nonEmptyString(variables[key])?.trimmingCharacters(in: .whitespacesAndNewlines) else {
      return nil
    }
    return value.isEmpty ? nil : value
  }

  private func first(config: JSONObject, variables: JSONObject, addonName: String) throws -> Int {
    let raw = intValue(config["first"]) ?? intFromRenderedString(variables["first"]) ?? intValue(variables["first"]) ?? Self.defaultFirst
    guard raw > 0 && raw <= Self.maxFirst else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) first must be between 1 and \(Self.maxFirst)")
    }
    return raw
  }

  private func optionalBool(
    _ key: String,
    config: JSONObject,
    variables: JSONObject,
    addonName: String
  ) throws -> Bool? {
    if let value = boolValue(config[key]) ?? boolFromRenderedString(variables[key]) ?? boolValue(variables[key]) {
      return value
    }
    if case let .string(value)? = variables[key], value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return nil
    }
    guard config[key] == nil && variables[key] == nil else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) \(key) must be a boolean")
    }
    return nil
  }

  private func maxDownloadBytes(config: JSONObject, addonName: String) throws -> Int {
    let value: Int
    if let configValue = config["maxDownloadBytes"] {
      guard let configInt = intValue(configValue) else {
        throw AdapterExecutionError(.policyBlocked, "\(addonName) maxDownloadBytes must be an integer")
      }
      value = configInt
    } else {
      value = Self.defaultMaxDownloadBytes
    }
    guard value >= 0 else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) maxDownloadBytes must be non-negative")
    }
    return value
  }

  private func materializationFlag(
    _ key: String,
    defaultValue: Bool,
    config: JSONObject,
    addonName: String
  ) throws -> Bool {
    if let configValue = config[key] {
      guard let value = boolValue(configValue) else {
        throw AdapterExecutionError(.policyBlocked, "\(addonName) \(key) must be a boolean")
      }
      return value
    }
    return defaultValue
  }

  private func boolFromRenderedString(_ value: JSONValue?) -> Bool? {
    guard case let .string(text)? = value else {
      return nil
    }
    switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "true":
      return true
    case "false":
      return false
    default:
      return nil
    }
  }

  private func intFromRenderedString(_ value: JSONValue?) -> Int? {
    guard case let .string(text)? = value else {
      return nil
    }
    return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private func skipEntry(_ descriptor: AppleMailFileDescriptor, reason: String, actualByteSize: Int? = nil) -> JSONObject {
    var entry = descriptor.value
    entry["kind"] = .string(descriptor.kind)
    entry["reason"] = .string(reason)
    if let actualByteSize {
      entry["materializedByteSize"] = .integer(Int64(actualByteSize))
    }
    return entry
  }

  private func uniqueFilename(preferred: String?, fallback: String, usedNames: inout [String: Int]) -> String {
    let base = sanitizedFilename(preferred, fallback: fallback)
    let count = usedNames[base] ?? 0
    usedNames[base] = count + 1
    guard count > 0 else {
      return base
    }
    let url = URL(fileURLWithPath: base)
    let ext = url.pathExtension
    let stem = ext.isEmpty ? base : url.deletingPathExtension().lastPathComponent
    return ext.isEmpty ? "\(stem)-\(count + 1)" : "\(stem)-\(count + 1).\(ext)"
  }

  private func sanitizedFilename(_ value: String?, fallback: String) -> String {
    let scalarSet = CharacterSet.controlCharacters.union(.newlines)
    let raw = value?.components(separatedBy: scalarSet).joined(separator: "") ?? ""
    let leaf = raw
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: "\\", with: "-")
      .replacingOccurrences(of: "..", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmed = leaf.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    return trimmed.isEmpty ? fallback : trimmed
  }

  private func isFullDiskAccessText(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return lowered.contains("full disk access")
      || lowered.contains("mailfulldiskaccess")
      || lowered.contains("mail full disk access")
      || lowered.contains("operation not permitted")
      || lowered.contains("permission denied")
  }

  private func fullDiskAccessError(_ addonName: String, detail: String) -> AdapterExecutionError {
    AdapterExecutionError(
      .policyBlocked,
      "\(addonName) requires Apple Mail Full Disk Access. \(Self.fdaGuidance) Detail: \(appleGatewayCompactText(detail))"
    )
  }

  private func mailMessage(fromEdge value: JSONValue, index: Int, addonName: String) throws -> JSONObject {
    guard case let .object(edge) = value else {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) GraphQL data.mailMessages.edges[\(index)] must be an object")
    }
    guard case var .object(node)? = edge["node"] else {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) GraphQL data.mailMessages.edges[\(index)].node must be an object")
    }
    if let cursor = nonEmptyString(edge["cursor"]) {
      node["cursor"] = .string(cursor)
    }
    return node
  }
}

private struct AppleMailFileDescriptor {
  var kind: String
  var value: JSONObject
}

private struct AppleMailMaterializationResult {
  var downloadRoot: String
  var materialized: [JSONObject]
  var skipped: [JSONObject]
}
