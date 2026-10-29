import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import GatewaySDKKit
#if canImport(GmailGatewayCore)
import GmailGatewayCore
#endif
import RielaAddonSupport
import RielaCore

/// Runs one GraphQL document against the gateway library backing an add-on
/// tier and returns the JSON envelope that gateway's CLI would have printed on
/// stdout. The gateway runs inside the riela process; `environment` is the
/// only environment it can observe.
typealias LocalGatewayGraphQLRunner = @Sendable (
  _ tier: String,
  _ document: String,
  _ variablesJSON: String?,
  _ environment: [String: String]
) async throws -> String

/// Static description of one local gateway tier.
///
/// The tier is pinned per add-on, so a workflow cannot widen it through inputs
/// or payload data. The gateways are linked as libraries rather than launched
/// as executables, so the boundary is the role and capability list this
/// descriptor hands the gateway's own capability registry — which refuses a
/// document naming a capability outside the tier — instead of which binary was
/// on `PATH`.
struct LocalGatewayGraphQLDescriptor {
  var providerName: String
  var payloadNamespaceKey: String
  /// Reported in the add-on payload so a run records which tier answered.
  var tier: String
  /// Whether the legacy document mode accepts variablesTemplate. Gmail keeps
  /// its CLI-compatible restriction; its SDK operation mode accepts variables.
  var acceptsVariables: Bool
  /// addon.env may only populate target names this predicate accepts, so the
  /// binding mechanism cannot inject arbitrary variables into the gateway.
  var isAllowedEnvironmentTarget: (String) -> Bool
  var catalog: (() throws -> GatewaySchemaCatalog)?
  /// Optional provider-owned, normalized operational observations, separate from selected source data.
  var observationMetadata: ((String) -> JSONObject)?
  var run: LocalGatewayGraphQLRunner
}

/// Shared engine for built-in add-ons that call a sibling gateway package's
/// GraphQL runtime and read its JSON envelope.
struct LocalGatewayGraphQLEngine {
  var environment: [String: String]
  var descriptor: LocalGatewayGraphQLDescriptor
  var workingDirectory: URL

  init(
    environment: [String: String],
    descriptor: LocalGatewayGraphQLDescriptor,
    runnerOverride: LocalGatewayGraphQLRunner? = nil,
    workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  ) {
    self.environment = environment
    self.descriptor = descriptor
    self.workingDirectory = workingDirectory
    if let runnerOverride {
      self.descriptor.run = runnerOverride
    }
  }

  func execute(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext,
    documentOverride: String? = nil
  ) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    let config = input.addon.config ?? [:]
    let nowVariables = try localGatewayNowVariables(config: config, addonName: input.addon.name)
      .mapValues(JSONValue.string)
    let variables = try addonVariables(for: input, additionalVariables: nowVariables)
    var childEnvironment = try resolvedChildEnvironment(input)
    if descriptor.providerName == "notion-gateway", descriptor.tier == "writer",
       config["operation"] == .string("uploadLocalFile") {
      return try await executeNotionLocalFileUpload(
        input: input, config: config, runner: descriptor.run, variables: variables,
        childEnvironment: childEnvironment, runtimeEnvironment: environment, workingDirectory: workingDirectory, context: context
      )
    }
    if descriptor.providerName == "notion-gateway", descriptor.tier == "writer",
       config["operation"] == .string("publishPage") {
      return try await executeNotionPublishPage(
        input: input, config: config, runner: descriptor.run, variables: variables,
        childEnvironment: childEnvironment, runtimeEnvironment: environment,
        workingDirectory: workingDirectory, context: context
      )
    }
    if descriptor.providerName == "gmail-gateway" {
      childEnvironment.merge(try gatewayWriteRetryEnvironment(input, prefix: "GMAIL_GATEWAY_")) { _, configured in configured }
    }
    let document: String
    let variablesJSON: String?
    if config["operation"] != nil && documentOverride == nil {
      guard let catalog = descriptor.catalog else {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) does not support JSON operations")
      }
      let built = try BuiltinGatewayJSONRequest.document(
        config: config, variables: variables, catalog: catalog(), addonName: input.addon.name
      )
      document = built.document
      variablesJSON = String(bytes: try JSONEncoder().encode(built.variables), encoding: .utf8)
    } else {
      document = try documentOverride ?? renderedDocument(config: config, variables: variables, addonName: input.addon.name)
      if descriptor.acceptsVariables {
        variablesJSON = try renderedVariablesJSON(config: config, variables: variables, addonName: input.addon.name)
      } else {
        guard config["variablesTemplate"] == nil else {
          throw AdapterExecutionError(
            .policyBlocked,
            "\(input.addon.name) config.variablesTemplate is not supported; use config.operation with config.arguments"
          )
        }
        variablesJSON = nil
      }
    }
    let gatewayEnvironment = sanitizedGatewayEnvironment(
      runtimeEnvironment: environment,
      bindings: childEnvironment
    )
    let run = descriptor.run
    let tier = descriptor.tier
    let providerName = descriptor.providerName
    let stdout = try await localGatewayRunWithDeadline(
      deadline: context.deadline,
      addonName: input.addon.name,
      providerName: descriptor.providerName
    ) {
      #if canImport(GmailGatewayCore)
      if providerName == "gmail-gateway" {
        return try await GmailWriteExecutionContext.withDeadline(context.deadline) {
          try await run(tier, document, variablesJSON, gatewayEnvironment)
        }
      }
      #endif
      return try await run(tier, document, variablesJSON, gatewayEnvironment)
    }
    let envelope = try envelope(from: stdout, addonName: input.addon.name)
    guard envelope.errors.isEmpty else {
      let detail = appleGatewayCompactText(envelope.errors.joined(separator: "; "))
      throw AdapterExecutionError(.providerError, "\(input.addon.name) GraphQL errors: \(detail)")
    }
    var payloadRoot: JSONObject = ["data": .object(envelope.data)]
    if let selected = try localGatewaySelectedValue(
      config: config,
      variables: variables,
      payloadRoot: payloadRoot,
      addonName: input.addon.name
    ) {
      payloadRoot["selected"] = selected
    }
    let when = try localGatewayWhenFlags(config: config, payloadRoot: payloadRoot, addonName: input.addon.name)
    var payload: JSONObject = [
      "status": .string("ok"),
      "addon": .string(input.addon.name),
      "stepId": .string(input.stepId),
      "data": .object(envelope.data),
      "requestId": .string(envelope.requestId ?? ""),
      "replyText": .string("\(descriptor.providerName) \(descriptor.tier) query succeeded."),
      descriptor.payloadNamespaceKey: .object([
        // The gateway is linked into this process, so there is no resolved
        // binary to report; the tier that answered is the useful fact.
        "runtime": .object([
          "mode": .string("in-process"),
          "tier": .string(descriptor.tier)
        ]),
        "requestId": .string(envelope.requestId ?? "")
      ])
    ]
    if let observations = descriptor.observationMetadata?(stdout), !observations.isEmpty,
       case var .object(namespace)? = payload[descriptor.payloadNamespaceKey] {
      namespace["observations"] = .object(observations)
      payload[descriptor.payloadNamespaceKey] = .object(namespace)
    }
    if let selected = payloadRoot["selected"] {
      payload["selected"] = selected
    }
    for (key, value) in try localGatewayPayloadExtras(config: config, variables: variables, addonName: input.addon.name) {
      payload[key] = value
    }
    return AdapterExecutionOutput(
      provider: descriptor.providerName,
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: when,
      payload: payload
    )
  }

  private func resolvedChildEnvironment(_ input: WorkflowAddonExecutionInput) throws -> [String: String] {
    if let env = input.addon.env {
      for targetName in env.keys where !descriptor.isAllowedEnvironmentTarget(targetName) {
        throw AdapterExecutionError(
          .policyBlocked,
          "\(input.addon.name) addon.env target '\(targetName)' is not a \(descriptor.providerName) environment variable"
        )
      }
    }
    return try resolveAddonEnvironment(input.addon.env, runtimeEnvironment: environment)
  }

  private func renderedDocument(config: JSONObject, variables: JSONObject, addonName: String) throws -> String {
    guard let template = nonEmptyString(config["queryTemplate"]) else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.queryTemplate is required")
    }
    let document = renderPromptTemplate(template, variables: variables).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !document.isEmpty else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.queryTemplate rendered to an empty document")
    }
    return document
  }

  private func renderedVariablesJSON(
    config: JSONObject,
    variables: JSONObject,
    addonName: String
  ) throws -> String? {
    guard let value = config["variablesTemplate"] else {
      return nil
    }
    guard case let .object(template) = value else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.variablesTemplate must be an object")
    }
    let rendered = try template.mapValues { try renderAddonConfig($0, variables: variables) }
    do {
      return try JSONValue.object(rendered).compactJSONString()
    } catch {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.variablesTemplate failed to encode: \(error.localizedDescription)")
    }
  }

  private func envelope(
    from stdout: String,
    addonName: String
  ) throws -> AppleGatewayGraphQLEnvelope {
    try AppleGatewayGraphQLEnvelope(stdout: stdout, addonName: addonName)
  }
}

private func executeNotionLocalFileUpload(
  input: WorkflowAddonExecutionInput,
  config: JSONObject,
  runner: @escaping LocalGatewayGraphQLRunner,
  variables: JSONObject,
  childEnvironment: [String: String],
  runtimeEnvironment: [String: String],
  workingDirectory: URL,
  context: AdapterExecutionContext
) async throws -> AdapterExecutionOutput {
  let addonName = input.addon.name
  guard config["queryTemplate"] == nil, config["variablesTemplate"] == nil, config["selection"] == nil,
        config["select"] == nil, config["command"] == nil, config["argsTemplate"] == nil else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) uploadLocalFile cannot be mixed with a GraphQL document or selection")
  }
  let arguments = try BuiltinGatewayJSONRequest.renderedArguments(config: config, variables: variables, addonName: addonName)
  let supportedArguments: Set<String> = ["path", "filename", "contentType", "kind", "caption"]
  guard arguments.keys.allSatisfy(supportedArguments.contains) else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) uploadLocalFile contains an unsupported argument")
  }
  for key in supportedArguments where arguments[key] != nil {
    guard case .string? = arguments[key] else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) uploadLocalFile argument \(key) must be a string")
    }
  }
  guard let path = nonEmptyString(arguments["path"]) else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) uploadLocalFile requires arguments.path")
  }
  let root = workingDirectory.standardizedFileURL
  let resolved = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
  var permittedRoots = [root.resolvingSymlinksInPath().standardizedFileURL]
  if let artifactPath = runtimeEnvironment["RIELA_ARTIFACT_DIR"], !artifactPath.isEmpty {
    permittedRoots.append(URL(fileURLWithPath: artifactPath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL)
  }
  permittedRoots.append(contentsOf: try notionLocalFileRoots(config: config, variables: variables, addonName: addonName)
    .map { URL(fileURLWithPath: $0, isDirectory: true, relativeTo: root).resolvingSymlinksInPath().standardizedFileURL })
  guard permittedRoots.contains(where: { resolved.path == $0.path || resolved.path.hasPrefix($0.path + "/") }) else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) uploadLocalFile path is outside the working and artifact directories")
  }
  let data: Data
  let sizeBytes: Int64
  do { (data, sizeBytes) = try readNotionUploadFile(resolved, limit: 20 * 1_024 * 1_024) } catch {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) uploadLocalFile file could not be read as a non-empty regular file within 20 MiB")
  }
  let filename = nonEmptyString(arguments["filename"]) ?? resolved.lastPathComponent
  let contentType = nonEmptyString(arguments["contentType"]) ?? notionUploadContentType(data: data, filename: filename)
  let kind = nonEmptyString(arguments["kind"]) ?? (contentType.lowercased().hasPrefix("image/") ? "image" : "file")
  guard kind == "image" || kind == "file" else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) uploadLocalFile kind must be image or file")
  }
  guard kind != "image" || contentType.lowercased().hasPrefix("image/") else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) image upload requires an image contentType")
  }
  let createField = kind == "image" ? "createFileUpload" : "createAttachmentUpload"
  let sendField = kind == "image" ? "sendFileUpload" : "sendAttachmentUpload"
  let createDocument = "mutation($filename:String!,$contentType:String!){\(createField)(filename:$filename,contentType:$contentType)}"
  let createVariables = try notionUploadVariables(["filename": .string(filename), "contentType": .string(contentType)])
  let gatewayEnvironment = sanitizedGatewayEnvironment(runtimeEnvironment: runtimeEnvironment, bindings: childEnvironment)
  let created = try await notionUploadCall(runner: runner, document: createDocument, variables: createVariables,
    environment: gatewayEnvironment, context: context, addonName: addonName)
  let createdField = try created.mutationField(createField, addonName: addonName)
  guard let uploadId = nonEmptyString(createdField["id"]) else {
    throw AdapterExecutionError(.invalidOutput, "\(addonName) upload create response is missing an id")
  }
  let sendDocument = "mutation($id:ID!,$filename:String!,$contentType:String!,$dataBase64:String!){\(sendField)(id:$id,filename:$filename,contentType:$contentType,dataBase64:$dataBase64)}"
  let sendVariables = try notionUploadVariables([
    "id": .string(uploadId), "filename": .string(filename), "contentType": .string(contentType),
    "dataBase64": .string(data.base64EncodedString())
  ])
  let sent = try await notionUploadCall(runner: runner, document: sendDocument, variables: sendVariables,
    environment: gatewayEnvironment, context: context, addonName: addonName)
  let sentField = try sent.mutationField(sendField, addonName: addonName)
  guard let uploadStatus = nonEmptyString(sentField["status"]) else {
    throw AdapterExecutionError(.invalidOutput, "\(addonName) upload send response is missing a status")
  }
  let caption = nonEmptyString(arguments["caption"]).map { [
    JSONValue.object(["type": .string("text"), "text": .object(["content": .string($0)])])
  ] } ?? []
  let blockType = kind == "image" ? "image" : "file"
  let inner: JSONObject = ["type": .string("file_upload"), "file_upload": .object(["id": .string(uploadId)])]
  var blockBody: JSONObject = ["type": .string(blockType), blockType: .object(inner)]
  if !caption.isEmpty { blockBody[blockType] = .object(inner.merging(["caption": .array(caption)]) { _, rhs in rhs }) }
  let block = JSONValue.object(["object": .string("block")].merging(blockBody) { _, rhs in rhs })
  let payload: JSONObject = [
    "status": .string("ok"), "addon": .string(addonName), "stepId": .string(input.stepId),
    "data": .object(["uploadLocalFile": .object(sentField)]), "requestId": .string(sent.requestId ?? ""),
    "replyText": .string("notion-gateway writer upload succeeded."),
    "block": block,
    "notionGateway": .object([
      "runtime": .object(["mode": .string("in-process"), "tier": .string("writer")]),
      "requestId": .string(sent.requestId ?? ""), "fileUploadId": .string(uploadId),
      "filename": .string(filename), "contentType": .string(contentType), "sizeBytes": .integer(sizeBytes),
      "status": .string(uploadStatus), "block": block
    ])
  ]
  return AdapterExecutionOutput(provider: "notion-gateway", model: addonName, promptText: "", completionPassed: true,
    when: ["success": true], payload: payload)
}

private struct NotionPublishedUpload: Sendable {
  var id: String
  var status: String
}

private struct NotionUploadFailure: Error, Sendable {
  var message: String
}

private struct DeferredNotionChildren {
  var parentPath: [Int]
  var children: [JSONValue]
}

private func executeNotionPublishPage(
  input: WorkflowAddonExecutionInput, config: JSONObject, runner: @escaping LocalGatewayGraphQLRunner,
  variables: JSONObject, childEnvironment: [String: String], runtimeEnvironment: [String: String],
  workingDirectory: URL, context: AdapterExecutionContext
) async throws -> AdapterExecutionOutput {
  let addonName = input.addon.name
  guard config["queryTemplate"] == nil, config["variablesTemplate"] == nil, config["selection"] == nil,
        config["select"] == nil, config["command"] == nil, config["argsTemplate"] == nil else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) publishPage accepts children only; markdown and GraphQL documents are not supported")
  }
  let arguments = try BuiltinGatewayJSONRequest.renderedArguments(config: config, variables: variables, addonName: addonName)
  guard arguments["markdown"] == nil else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) publishPage does not support markdown; provide native children blocks")
  }
  let allowed: Set<String> = ["parentId", "pageId", "path", "title", "children", "position"]
  let existingPageId = nonEmptyString(arguments["pageId"])
  guard arguments.keys.allSatisfy(allowed.contains),
        existingPageId != nil || (nonEmptyString(arguments["parentId"]) != nil && nonEmptyString(arguments["title"]) != nil),
        case let .array(rawBlocks)? = arguments["children"] else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) publishPage requires parentId, title, and children; unsupported arguments are rejected")
  }
  let parentId = nonEmptyString(arguments["parentId"]) ?? ""
  let title = nonEmptyString(arguments["title"]) ?? ""
  let allowAttachments = config["allowLocalFileAttachments"] == .bool(true)
  let configuredLocalFileRoots = try notionLocalFileRoots(config: config, variables: variables, addonName: addonName)
  var effectiveParentId = parentId
  if existingPageId == nil, case let .array(titles)? = arguments["path"], !titles.isEmpty {
    guard titles.allSatisfy({ if case .string = $0 { true } else { false } }) else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) publishPage path must be an array of page titles")
    }
    let pathVariables: JSONObject = ["parentId": .string(parentId), "titles": .array(titles)]
    let pathResult = try await notionPublishCall(runner: runner,
      document: "mutation($parentId:ID!,$titles:[String!]!){ensurePagePath(parentId:$parentId,titles:$titles)}",
      variables: pathVariables, environment: runtimeEnvironment, bindings: childEnvironment, context: context, addonName: addonName)
    let pathObject: JSONObject = pathResult.data.values.first.flatMap { if case let .object(obj) = $0 { obj } else { nil } } ?? [:]
    let pathValue = pathObject["id"]
    guard let resolved = notionString(pathValue) else {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) ensurePagePath response is missing an id")
    }
    effectiveParentId = resolved
  } else if existingPageId == nil, arguments["path"] != nil, arguments["path"] != .null, case .array? = arguments["path"] {} else if existingPageId == nil, arguments["path"] != nil, arguments["path"] != .null {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) publishPage path must be an array")
  }

  var paths: [String: String] = [:]
  collectLocalFilePaths(rawBlocks, into: &paths, allowAttachments: allowAttachments, baseDirectory: workingDirectory)
  var uploadIds: [String: String] = [:]
  var uploaded: [JSONValue] = []
  var failures: [JSONValue] = []
  let orderedPaths = paths.keys.sorted()
  let localFileKinds = paths
  let uploadResults = await withTaskGroup(of: (String, Result<NotionPublishedUpload, NotionUploadFailure>).self) { group in
    var results: [(String, Result<NotionPublishedUpload, NotionUploadFailure>)] = []
    var nextIndex = 0
    let initialCount = min(3, orderedPaths.count)
    for _ in 0..<initialCount {
      let path = orderedPaths[nextIndex]
      nextIndex += 1
      group.addTask {
        do {
          let upload = try await uploadNotionLocalPath(path, runtimeEnvironment: runtimeEnvironment,
            bindings: childEnvironment, kind: localFileKinds[path] ?? "image", workingDirectory: workingDirectory, runner: runner,
            context: context, input: input, addonName: addonName, roots: configuredLocalFileRoots)
          return (path, .success(upload))
        } catch {
          return (path, .failure(NotionUploadFailure(message: notionPublishErrorMessage(error))))
        }
      }
    }
    while let result = await group.next() {
      results.append(result)
      guard nextIndex < orderedPaths.count else { continue }
      let path = orderedPaths[nextIndex]
      nextIndex += 1
      group.addTask {
        do {
          let upload = try await uploadNotionLocalPath(path, runtimeEnvironment: runtimeEnvironment,
            bindings: childEnvironment, kind: localFileKinds[path] ?? "image", workingDirectory: workingDirectory, runner: runner,
            context: context, input: input, addonName: addonName, roots: configuredLocalFileRoots)
          return (path, .success(upload))
        } catch {
          return (path, .failure(NotionUploadFailure(message: notionPublishErrorMessage(error))))
        }
      }
    }
    return results.sorted { $0.0 < $1.0 }
  }
  for (path, result) in uploadResults {
    switch result {
    case let .success(upload):
      uploadIds[path] = upload.id
      uploaded.append(.object(["path": .string(path), "id": .string(upload.id), "status": .string(upload.status)]))
    case let .failure(failure):
      failures.append(.object(["path": .string(path), "message": .string(failure.message)]))
    }
  }
  let normalizedBlocks = rawBlocks.flatMap { normalizeNotionBlock($0, uploadIds: uploadIds, failures: &failures, paths: paths, allowAttachments: allowAttachments, baseDirectory: workingDirectory) }
  let blockCount = notionBlockCount(normalizedBlocks)
  let (blocks, deferredChildren) = stripDeepNotionChildren(normalizedBlocks)
  let position = arguments["position"]
  var pageId: String? = existingPageId
  var pageURL = ""
  var createdBlockIDs: [String: String] = [:]
  var appendRequests = 0
  do {
    let chunks = try notionBlockChunks(blocks)
    let first = chunks.first ?? []
    var create: AppleGatewayGraphQLEnvelope?
    if let existingPageId {
      var nextIndex = 0
      for chunk in chunks {
        let appendResponse = try await notionPublishCall(runner: runner,
          document: "mutation($pageId:ID!,$children:JSON!){appendBlocks(id:$pageId,children:$children)}",
          variables: ["pageId": .string(existingPageId), "children": .array(chunk)], environment: runtimeEnvironment,
          bindings: childEnvironment, context: context, addonName: addonName)
        let appendResult: JSONObject = appendResponse.data.values.first.flatMap { if case let .object(obj) = $0 { obj } else { nil } } ?? [:]
        indexNotionResultIDs(appendResult, offset: nextIndex, path: [], into: &createdBlockIDs)
        nextIndex += chunk.count
        appendRequests += 1
      }
    } else {
      let createVariables: JSONObject = ["parentId": .string(effectiveParentId), "title": .string(title),
        "children": first.isEmpty ? .null : .array(first)].merging(position.map { ["position": $0] } ?? [:]) { _, rhs in rhs }
      let response = try await notionPublishCall(runner: runner,
        document: "mutation($parentId:ID!,$title:String!,$children:JSON,$position:JSON){createPage(parentId:$parentId,title:$title,children:$children,position:$position)}",
        variables: createVariables, environment: runtimeEnvironment, bindings: childEnvironment, context: context, addonName: addonName)
      create = response
      let created: JSONObject = response.data.values.first.flatMap { if case let .object(obj) = $0 { obj } else { nil } } ?? [:]
      indexNotionResultIDs(created, offset: 0, path: [], into: &createdBlockIDs)
      guard let id = notionString(created["id"]) else { throw AdapterExecutionError(.invalidOutput, "\(addonName) createPage response is missing an id") }
      pageId = id
      pageURL = notionString(created["url"]) ?? ""
      var nextIndex = first.count
      for chunk in chunks.dropFirst() {
        let appendResponse = try await notionPublishCall(runner: runner,
          document: "mutation($pageId:ID!,$children:JSON!){appendBlocks(id:$pageId,children:$children)}",
          variables: ["pageId": .string(id), "children": .array(chunk)], environment: runtimeEnvironment,
          bindings: childEnvironment, context: context, addonName: addonName)
        let appendResult: JSONObject = appendResponse.data.values.first.flatMap { if case let .object(obj) = $0 { obj } else { nil } } ?? [:]
        indexNotionResultIDs(appendResult, offset: nextIndex, path: [], into: &createdBlockIDs)
        nextIndex += chunk.count
        appendRequests += 1
      }
    }
    let id = try requireNotionPageID(pageId, addonName: addonName)
    var deferredQueue = deferredChildren
    while !deferredQueue.isEmpty {
      let deferred = deferredQueue.removeFirst()
      let (shallowChildren, nestedDeferred) = stripDeepNotionChildren(deferred.children)
      deferredQueue.append(contentsOf: nestedDeferred.map {
        DeferredNotionChildren(parentPath: deferred.parentPath + $0.parentPath, children: $0.children)
      })
      let targetId = try await notionBlockID(at: deferred.parentPath, pageId: id, knownIDs: createdBlockIDs, runner: runner,
        environment: runtimeEnvironment, bindings: childEnvironment, context: context, addonName: addonName)
      let chunks = try notionBlockChunks(shallowChildren)
      var indexOffset = 0
      for chunk in chunks {
        let appendResponse = try await notionPublishCall(runner: runner,
          document: "mutation($id:ID!,$children:JSON!){appendBlocks(id:$id,children:$children)}",
          variables: ["id": .string(targetId), "children": .array(chunk)], environment: runtimeEnvironment,
          bindings: childEnvironment, context: context, addonName: addonName)
        let appendResult: JSONObject = appendResponse.data.values.first.flatMap { if case let .object(obj) = $0 { obj } else { nil } } ?? [:]
        indexNotionResultIDs(appendResult, offset: indexOffset, path: deferred.parentPath, into: &createdBlockIDs)
        indexOffset += chunk.count
        appendRequests += 1
      }
    }
    let pageResult: JSONObject = ["pageId": .string(id), "url": .string(pageURL), "parentId": .string(effectiveParentId),
      "uploadedFiles": .array(uploaded), "failedUploads": .array(failures), "appendRequests": .integer(Int64(appendRequests)),
      "blocks": .integer(Int64(blockCount))]
    return notionPublishOutput(input: input, result: pageResult, requestId: create?.requestId)
  } catch {
    guard let pageId else { throw error }
    let partial: JSONObject = ["pageId": .string(pageId), "url": .string(pageURL), "parentId": .string(effectiveParentId),
      "uploadedFiles": .array(uploaded), "failedUploads": .array(failures), "appendRequests": .integer(Int64(appendRequests)),
      "blocks": .integer(Int64(blockCount)), "incomplete": .bool(true), "error": .string(notionPublishErrorMessage(error))]
    let partialJSON = (try? JSONValue.object(partial).compactJSONString()) ?? "{}"
    throw AdapterExecutionError(.providerError, "publishPage incomplete: \(partialJSON)")
  }
}

private func notionPublishErrorMessage(_ error: Error) -> String {
  (error as? AdapterExecutionError)?.message ?? error.localizedDescription
}

private func notionPublishOutput(input: WorkflowAddonExecutionInput, result: JSONObject, requestId: String?) -> AdapterExecutionOutput {
  let payload: JSONObject = ["status": .string("ok"), "addon": .string(input.addon.name), "stepId": .string(input.stepId),
    "data": .object(["publishPage": .object(result)]), "requestId": .string(requestId ?? ""),
    "replyText": .string("notion-gateway writer page published."), "notionGateway": .object(["runtime": .object(["mode": .string("in-process"), "tier": .string("writer")])])]
  return AdapterExecutionOutput(provider: "notion-gateway", model: input.addon.name, promptText: "", completionPassed: true,
    when: ["success": true], payload: payload)
}

private func notionLocalFileRoots(config: JSONObject, variables: JSONObject, addonName: String) throws -> [String] {
  guard let value = config["localFileRoots"] else { return [] }
  guard case let .array(values) = try renderAddonConfig(value, variables: variables),
        values.allSatisfy({ nonEmptyString($0) != nil }) else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) localFileRoots must be an array of non-empty paths")
  }
  return values.compactMap(nonEmptyString)
}

private func collectLocalFilePaths(_ blocks: [JSONValue], into paths: inout [String: String], allowAttachments: Bool, baseDirectory: URL) {
  for block in blocks { collectLocalFilePaths(in: block, into: &paths, allowAttachments: allowAttachments, baseDirectory: baseDirectory) }
}

private func collectLocalFilePaths(in value: JSONValue, into paths: inout [String: String], allowAttachments: Bool, baseDirectory: URL) {
  guard case let .object(object) = value else {
    if case let .array(values) = value { collectLocalFilePaths(values, into: &paths, allowAttachments: allowAttachments, baseDirectory: baseDirectory) }
    return
  }
  if case let .string(type)? = object["type"], ["image", "file"].contains(type),
     type == "image" || allowAttachments, case let .object(payload)? = object[type], payload["type"] == .string("local_file"),
     case let .object(local)? = payload["local_file"], let path = nonEmptyString(local["path"]) {
    let standardized = URL(fileURLWithPath: path, relativeTo: baseDirectory).standardizedFileURL.path
    paths[standardized] = type
  }
  for (key, child) in object where key == "children" || childIsPotentialBlockContainer(key: key, value: child) {
    collectLocalFilePaths(in: child, into: &paths, allowAttachments: allowAttachments, baseDirectory: baseDirectory)
  }
}

private func childIsPotentialBlockContainer(key: String, value: JSONValue) -> Bool {
  key == "children" || (ifObject(value) != nil && key != "local_file" && key != "file_upload")
}

private func ifObject(_ value: JSONValue) -> JSONObject? {
  guard case let .object(object) = value else { return nil }
  return object
}

private func notionString(_ value: JSONValue?) -> String? {
  guard case let .string(text)? = value else { return nil }
  return text
}

private func normalizeNotionBlock(_ block: JSONValue, uploadIds: [String: String], failures: inout [JSONValue], paths: [String: String], allowAttachments: Bool, baseDirectory: URL) -> [JSONValue] {
  guard case var .object(object) = block, case let .string(type)? = object["type"] else { return [block] }
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

private func notionBlockCount(_ blocks: [JSONValue]) -> Int {
  blocks.reduce(into: 0) { count, block in
    count += 1
    guard case let .object(object) = block, let type = notionString(object["type"]) else { return }
    if case let .array(children)? = object["children"] { count += notionBlockCount(children) }
    if case let .object(body)? = object[type], case let .array(children)? = body["children"] { count += notionBlockCount(children) }
  }
}

private func notionBlockChunks(_ blocks: [JSONValue]) throws -> [[JSONValue]] {
  var chunks: [[JSONValue]] = []
  var current: [JSONValue] = []
  for block in blocks {
    let candidate = current + [block]
    let encodedSize = try JSONValue.array(candidate).compactJSONString().utf8.count
    if !current.isEmpty && (candidate.count > 100 || notionBlockCount(candidate) > 900 || encodedSize > 399_488) {
      chunks.append(current)
      current = [block]
      guard notionBlockCount(current) <= 900, try JSONValue.array(current).compactJSONString().utf8.count <= 399_488 else {
        throw AdapterExecutionError(.policyBlocked, "publishPage block exceeds Notion request limits")
      }
    } else {
      current = candidate
    }
  }
  if !current.isEmpty { chunks.append(current) }
  return chunks
}

private func requireNotionPageID(_ id: String?, addonName: String) throws -> String {
  guard let id, !id.isEmpty else { throw AdapterExecutionError(.invalidOutput, "\(addonName) page id is unavailable") }
  return id
}

private func indexNotionResultIDs(_ result: JSONObject, offset: Int, path: [Int], into ids: inout [String: String]) {
  guard case let .array(results)? = result["results"] else { return }
  for (index, item) in results.enumerated() {
    guard case let .object(block) = item else { continue }
    let blockPath = path + [offset + index]
    if let id = nonEmptyString(block["id"]) { ids[blockPath.map(String.init).joined(separator: ".")] = id }
    for value in block.values {
      guard case let .object(body) = value else { continue }
      indexNotionResultIDs(body, offset: 0, path: blockPath, into: &ids)
    }
  }
}

private func stripDeepNotionChildren(_ blocks: [JSONValue]) -> ([JSONValue], [DeferredNotionChildren]) {
  var deferred: [DeferredNotionChildren] = []
  let shallow = blocks.enumerated().map { index, block in
    stripDeepNotionChildren(block, depth: 1, path: [index], deferred: &deferred)
  }
  return (shallow, deferred)
}

private func stripDeepNotionChildren(
  _ block: JSONValue,
  depth: Int,
  path: [Int],
  deferred: inout [DeferredNotionChildren]
) -> JSONValue {
  guard case var .object(object) = block, case let .string(type)? = object["type"] else { return block }
  for key in Array(object.keys) {
    if key == "children", case let .array(children)? = object[key] {
      if depth >= 3 || children.count > 100, type != "column_list", type != "table" {
        object.removeValue(forKey: key)
        deferred.append(DeferredNotionChildren(parentPath: path, children: children))
      } else {
        object[key] = .array(children.enumerated().map { index, child in
          stripDeepNotionChildren(child, depth: depth + 1, path: path + [index], deferred: &deferred)
        })
      }
    } else if let value = object[key], var body = ifObject(value), case let .array(children)? = body["children"] {
      if depth >= 3 || children.count > 100, type != "column_list", type != "table" {
        body.removeValue(forKey: "children")
        object[key] = .object(body)
        deferred.append(DeferredNotionChildren(parentPath: path, children: children))
      } else {
        body["children"] = .array(children.enumerated().map { index, child in
          stripDeepNotionChildren(child, depth: depth + 1, path: path + [index], deferred: &deferred)
        })
        object[key] = .object(body)
      }
    }
  }
  return .object(object)
}

private func notionBlockID(
  at path: [Int],
  pageId: String,
  knownIDs: [String: String],
  runner: @escaping LocalGatewayGraphQLRunner,
  environment: [String: String],
  bindings: [String: String],
  context: AdapterExecutionContext,
  addonName: String
) async throws -> String {
  if let known = knownIDs[path.map(String.init).joined(separator: ".")] { return known }
  var parentId = pageId
  for index in path {
    var cursor: JSONValue?
    var children: [JSONValue] = []
    repeat {
      var variables: JSONObject = ["id": .string(parentId), "pageSize": .integer(100)]
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
    parentId = id
  }
  return parentId
}

private func uploadNotionLocalPath(
  _ path: String,
  runtimeEnvironment: [String: String],
  bindings: [String: String],
  kind: String,
  workingDirectory: URL,
  runner: @escaping LocalGatewayGraphQLRunner,
  context: AdapterExecutionContext,
  input: WorkflowAddonExecutionInput,
  addonName: String,
  roots: [String]
) async throws -> NotionPublishedUpload {
  let config: JSONObject = ["arguments": .object(["path": .string(path), "kind": .string(kind)]), "localFileRoots": .array(roots.map(JSONValue.string))]
  let output = try await executeNotionLocalFileUpload(
    input: input, config: config, runner: runner, variables: [:], childEnvironment: bindings,
    runtimeEnvironment: runtimeEnvironment, workingDirectory: workingDirectory, context: context
  )
  guard case let .object(namespace)? = output.payload["notionGateway"],
        let id = nonEmptyString(namespace["fileUploadId"]) else {
    throw AdapterExecutionError(.invalidOutput, "\(addonName) local upload response is missing a file upload id")
  }
  return NotionPublishedUpload(id: id, status: nonEmptyString(namespace["status"]) ?? "uploaded")
}

private func notionPublishCall(
  runner: @escaping LocalGatewayGraphQLRunner,
  document: String,
  variables: JSONObject,
  environment: [String: String],
  bindings: [String: String],
  context: AdapterExecutionContext,
  addonName: String
) async throws -> AppleGatewayGraphQLEnvelope {
  try await notionUploadCall(runner: runner, document: document, variables: notionUploadVariables(variables),
    environment: sanitizedGatewayEnvironment(runtimeEnvironment: environment, bindings: bindings), context: context, addonName: addonName)
}

private func notionUploadVariables(_ variables: JSONObject) throws -> String {
  let data = try JSONEncoder().encode(JSONValue.object(variables))
  guard let string = String(data: data, encoding: .utf8) else {
    throw AdapterExecutionError(.invalidOutput, "notion-gateway upload variables could not be encoded")
  }
  return string
}

private func notionUploadCall(
  runner: @escaping LocalGatewayGraphQLRunner, document: String, variables: String, environment: [String: String],
  context: AdapterExecutionContext, addonName: String
) async throws -> AppleGatewayGraphQLEnvelope {
  let stdout = try await localGatewayRunWithDeadline(deadline: context.deadline, addonName: addonName, providerName: "notion-gateway") {
    try await runner("writer", document, variables, environment)
  }
  let envelope = try AppleGatewayGraphQLEnvelope(stdout: stdout, addonName: addonName)
  guard envelope.errors.isEmpty else {
    throw AdapterExecutionError(.providerError, "\(addonName) GraphQL errors: \(appleGatewayCompactText(envelope.errors.joined(separator: "; ")))")
  }
  return envelope
}

private func notionUploadContentType(filename: String) -> String {
  switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
  case "jpg", "jpeg": "image/jpeg"
  case "png": "image/png"
  case "gif": "image/gif"
  case "webp": "image/webp"
  default: "application/octet-stream"
  }
}

private func notionUploadContentType(data: Data, filename: String) -> String {
  let bytes = [UInt8](data.prefix(12))
  if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
  if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
  if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
  if bytes.count >= 12, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF", String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" { return "image/webp" }
  return notionUploadContentType(filename: filename)
}

private func readNotionUploadFile(_ url: URL, limit: Int) throws -> (Data, Int64) {
  let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
  guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
  defer { _ = close(descriptor) }
  var info = stat()
  guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size > 0,
        info.st_size <= limit else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno == 0 ? EINVAL : errno)) }
  let expected = Int(info.st_size)
  var data = Data(count: min(expected, limit) + 1)
  let readCount = data.withUnsafeMutableBytes { buffer -> Int in
    guard let base = buffer.baseAddress else { return -1 }
    var total = 0
    while total < buffer.count {
      let count = read(descriptor, base.advanced(by: total), buffer.count - total)
      if count < 0, errno == EINTR { continue }
      if count <= 0 { break }
      total += count
    }
    return total
  }
  guard readCount > 0, readCount <= limit else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno == 0 ? EFBIG : errno)) }
  data.count = readCount
  var finalInfo = stat()
  guard fstat(descriptor, &finalInfo) == 0, finalInfo.st_size == info.st_size,
        data.count == expected else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
  return (data, Int64(info.st_size))
}

/// Applies the step deadline to an in-process gateway call. A linked gateway
/// has no process to terminate, so the call is cancelled and the same timeout
/// error a spawned gateway would have produced is raised. The task group waits
/// for the cancelled operation, so an operation that blocks a thread must be
/// cancellation-aware (see `xGatewayRunOffCooperativePool`).
func localGatewayRunWithDeadline(
  deadline: Date?,
  addonName: String,
  providerName: String,
  operation: @escaping @Sendable () async throws -> String
) async throws -> String {
  guard let deadline else { return try await operation() }
  let remaining = deadline.timeIntervalSinceNow
  guard remaining > 0 else {
    throw AdapterExecutionError(.timeout, "\(addonName) exceeded its deadline before \(providerName) was called")
  }
  return try await withThrowingTaskGroup(of: String.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: .seconds(remaining))
      throw AdapterExecutionError(.timeout, "\(addonName) exceeded its deadline while calling \(providerName)")
    }
    defer { group.cancelAll() }
    guard let first = try await group.next() else {
      throw AdapterExecutionError(.invalidOutput, "\(addonName) produced no \(providerName) response")
    }
    return first
  }
}

func localGatewayNowVariables(config: JSONObject, addonName: String) throws -> [String: String] {
  guard let value = config["nowVariables"] else {
    return [:]
  }
  guard case let .object(offsets) = value else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) config.nowVariables must be an object")
  }
  let now = Date()
  var resolved: [String: String] = [:]
  for (name, offsetValue) in offsets {
    guard let offsetSeconds = intValue(offsetValue) else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.nowVariables.\(name) must be an integer second offset")
    }
    resolved[name] = localGatewayInstantString(now.addingTimeInterval(TimeInterval(offsetSeconds)))
  }
  return resolved
}

func localGatewaySelectedValue(
  config: JSONObject,
  variables: JSONObject,
  payloadRoot: JSONObject,
  addonName: String
) throws -> JSONValue? {
  guard let value = config["selectFirst"] else {
    return nil
  }
  guard case let .object(selector) = value else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) config.selectFirst must be an object")
  }
  guard let path = nonEmptyString(selector["path"]) else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) config.selectFirst.path is required")
  }
  guard case let .array(candidates)? = localGatewayLookupPath(path, in: payloadRoot) else {
    throw AdapterExecutionError(.invalidOutput, "\(addonName) config.selectFirst.path '\(path)' did not resolve to an array")
  }
  var conditions: JSONObject = [:]
  if let whereValue = selector["where"] {
    guard case let .object(rendered) = try renderAddonConfig(whereValue, variables: variables) else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.selectFirst.where must be an object")
    }
    conditions = rendered
  }
  let position = nonEmptyString(selector["position"]) ?? "first"
  guard position == "first" || position == "last" else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) config.selectFirst.position must be 'first' or 'last'")
  }
  let ordered: [JSONValue] = position == "last" ? candidates.reversed() : candidates
  let match = ordered.first { candidate in
    guard case let .object(entry) = candidate else {
      return false
    }
    return conditions.allSatisfy { key, expected in
      localGatewayConditionMatches(entry[key], expected)
    }
  }
  return match ?? JSONValue.null
}

func localGatewayWhenFlags(
  config: JSONObject,
  payloadRoot: JSONObject,
  addonName: String
) throws -> [String: Bool] {
  var flags: [String: Bool] = ["always": true, "ok": true]
  guard let value = config["whenFlags"] else {
    return flags
  }
  guard case let .object(flagPaths) = value else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) config.whenFlags must be an object")
  }
  for (flagName, pathValue) in flagPaths {
    guard case let .string(path) = pathValue, !path.isEmpty else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.whenFlags.\(flagName) must be a non-empty path string")
    }
    flags[flagName] = localGatewayTruthy(localGatewayLookupPath(path, in: payloadRoot))
  }
  return flags
}

func localGatewayPayloadExtras(
  config: JSONObject,
  variables: JSONObject,
  addonName: String
) throws -> JSONObject {
  guard let value = config["payloadExtras"] else {
    return [:]
  }
  guard case let .object(template) = value else {
    throw AdapterExecutionError(.policyBlocked, "\(addonName) config.payloadExtras must be an object")
  }
  return try template.mapValues { try renderAddonConfig($0, variables: variables) }
}

/// Dot-path lookup over a JSON object that also understands numeric array
/// indexes, so paths like `data.tasks.nodes.0.id` address the first node.
func localGatewayLookupPath(_ path: String, in root: JSONObject) -> JSONValue? {
  let keys = path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
  guard !keys.isEmpty else {
    return nil
  }
  var current: JSONValue? = .object(root)
  for key in keys {
    switch current {
    case let .object(object):
      current = object[key]
    case let .array(values):
      guard let index = Int(key), values.indices.contains(index) else {
        return nil
      }
      current = values[index]
    default:
      return nil
    }
  }
  return current
}

func localGatewayTruthy(_ value: JSONValue?) -> Bool {
  switch value {
  case nil, .null:
    return false
  case let .bool(flag):
    return flag
  case let .string(text):
    return !text.isEmpty
  case let .integer(number):
    return number != 0
  case let .number(number):
    return number != 0
  case let .array(values):
    return !values.isEmpty
  case let .object(object):
    return !object.isEmpty
  }
}

private func localGatewayValuesMatch(_ actual: JSONValue?, _ expected: JSONValue) -> Bool {
  guard let actual else {
    return expected == .null
  }
  if actual == expected {
    return true
  }
  if case let .string(expectedText) = expected, case let .integer(number) = actual {
    return String(number) == expectedText
  }
  return false
}

/// A where condition is either a plain value (equality) or an operator object
/// combining `contains`, `notContains`, and `ne`, all of which must hold.
private func localGatewayConditionMatches(_ actual: JSONValue?, _ condition: JSONValue) -> Bool {
  guard case let .object(operators) = condition,
        !operators.isEmpty,
        operators.keys.allSatisfy({ ["contains", "notContains", "ne"].contains($0) }) else {
    return localGatewayValuesMatch(actual, condition)
  }
  for (name, operand) in operators {
    switch name {
    case "contains", "notContains":
      guard case let .string(needle) = operand, case let .string(haystack)? = actual else {
        return false
      }
      let contains = haystack.contains(needle)
      if (name == "contains") != contains {
        return false
      }
    case "ne":
      if localGatewayValuesMatch(actual, operand) {
        return false
      }
    default:
      return false
    }
  }
  return true
}

private func localGatewayInstantString(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.string(from: date)
}
