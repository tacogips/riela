import Foundation
import RielaAddonSupport
import RielaCore

enum YouTubeGatewayReadRequest: Equatable, Sendable {
  enum Filter: Equatable, Sendable {
    case mine, channelId(String), ids([String]), mySubscribers, myRecentSubscribers
  }
  enum ChannelSelector: Equatable, Sendable { case ids([String]), forHandle(String), mine }
  enum PlaylistSelector: Equatable, Sendable { case playlistId(String), ids([String]) }
  case subscriptions(filter: Filter, forChannelId: String?, order: String?, parts: [String], maxResults: Int?, pageToken: String?)
  case videos(ids: [String], parts: [String], pageToken: String?)
  case channels(selector: ChannelSelector, parts: [String])
  case playlistItems(selector: PlaylistSelector, parts: [String], maxResults: Int?, pageToken: String?)
}

enum YouTubeGatewayReadEngine {
  static let addonName = "riela/youtube-gateway-read"
  static let operationArguments: [String: Set<String>] = [
    "subscriptions.list": ["mine", "channelId", "ids", "mySubscribers", "myRecentSubscribers", "forChannelId", "order", "parts", "maxResults", "pageToken"],
    "videos.list": ["ids", "parts", "pageToken"],
    "channels.list": ["ids", "forHandle", "mine", "parts"],
    "playlistItems.list": ["playlistId", "ids", "parts", "maxResults", "pageToken"]
  ]

  static func requestShapeIssue(config: JSONObject, inputs: JSONObject?) throws {
    guard Set(config.keys).isSubset(of: ["operation", "arguments"]),
      case let .string(operation)? = config["operation"], let allowed = operationArguments[operation] else {
      throw invalid("operation")
    }
    guard let value = config["arguments"] else { return }
    guard inputs?.isEmpty != false else { throw invalid("arguments") }
    if BuiltinGatewayRequestChecks.isExactPlaceholder(value) { return }
    guard case let .object(arguments) = value, Set(arguments.keys).isSubset(of: allowed) else {
      throw invalid("arguments")
    }
  }

  static func parse(operation: String, arguments: JSONObject) throws -> YouTubeGatewayReadRequest {
    guard let allowed = operationArguments[operation], Set(arguments.keys).isSubset(of: allowed) else {
      throw invalid("operation or arguments")
    }
    func string(_ key: String) throws -> String? {
      guard let value = arguments[key] else { return nil }
      guard case let .string(text) = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw invalid(key)
      }
      return text
    }
    func strings(_ key: String) throws -> [String]? {
      guard let value = arguments[key] else { return nil }
      guard case let .array(items) = value, !items.isEmpty, items.count <= 50 else { throw invalid(key) }
      return try items.map { item in
        guard case let .string(text) = item, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw invalid(key)
        }
        return text
      }
    }
    func flag(_ key: String) throws -> Bool {
      guard let value = arguments[key] else { return false }
      guard case .bool(true) = value else { throw invalid(key) }
      return true
    }
    func parts(_ allowed: Set<String>, defaults: [String]) throws -> [String] {
      let values = try strings("parts") ?? defaults
      guard Set(values).isSubset(of: allowed) else { throw invalid("parts") }
      return values
    }
    func maximum() throws -> Int? {
      guard let value = arguments["maxResults"] else { return nil }
      guard case let .integer(number) = value, (1...50).contains(number) else { throw invalid("maxResults") }
      return Int(number)
    }
    let commonParts: Set<String> = ["id", "snippet", "contentDetails"]
    switch operation {
    case "subscriptions.list":
      var filters: [YouTubeGatewayReadRequest.Filter] = []
      if try flag("mine") { filters.append(.mine) }
      if let value = try string("channelId") { filters.append(.channelId(value)) }
      if let value = try strings("ids") { filters.append(.ids(value)) }
      if try flag("mySubscribers") { filters.append(.mySubscribers) }
      if try flag("myRecentSubscribers") { filters.append(.myRecentSubscribers) }
      guard filters.count == 1 else { throw invalid("filter") }
      let order = try string("order")
      guard order == nil || ["alphabetical", "relevance", "unread"].contains(order ?? "") else { throw invalid("order") }
      return .subscriptions(filter: filters[0], forChannelId: try string("forChannelId"), order: order,
        parts: try parts(commonParts.union(["subscriberSnippet"]), defaults: ["snippet", "contentDetails"]),
        maxResults: try maximum(), pageToken: try string("pageToken"))
    case "videos.list":
      guard let ids = try strings("ids") else { throw invalid("ids") }
      return .videos(ids: ids, parts: try parts(commonParts.union(["statistics"]),
        defaults: ["snippet", "contentDetails", "statistics"]), pageToken: try string("pageToken"))
    case "channels.list":
      var selectors: [YouTubeGatewayReadRequest.ChannelSelector] = []
      if let value = try strings("ids") { selectors.append(.ids(value)) }
      if let value = try string("forHandle") { selectors.append(.forHandle(value)) }
      if try flag("mine") { selectors.append(.mine) }
      guard selectors.count == 1 else { throw invalid("selector") }
      return .channels(selector: selectors[0], parts: try parts(commonParts, defaults: ["snippet", "contentDetails"]))
    case "playlistItems.list":
      var selectors: [YouTubeGatewayReadRequest.PlaylistSelector] = []
      if let value = try string("playlistId") { selectors.append(.playlistId(value)) }
      if let value = try strings("ids") { selectors.append(.ids(value)) }
      guard selectors.count == 1 else { throw invalid("selector") }
      return .playlistItems(selector: selectors[0], parts: try parts(commonParts, defaults: ["snippet", "contentDetails"]),
        maxResults: try maximum(), pageToken: try string("pageToken"))
    default: throw invalid("operation")
    }
  }

  private static func invalid(_ field: String) -> AdapterExecutionError {
    AdapterExecutionError(.policyBlocked, "\(addonName) invalid \(field)")
  }
}

#if canImport(YouTubeGatewayCore)
import YouTubeGatewayCore

protocol YouTubeGatewayReadClient: Sendable {
  func list(_ options: SubscriptionListOptions) async throws -> SubscriptionPage
  func videosList(_ options: VideoListOptions) async throws -> VideoPage
  func channelsList(_ options: ChannelListOptions) async throws -> ChannelPage
  func playlistItemsList(_ options: PlaylistItemsListOptions) async throws -> PlaylistItemsPage
}
extension YouTubeClient: YouTubeGatewayReadClient {}

extension YouTubeGatewayReadEngine {
  static func execute(_ request: YouTubeGatewayReadRequest, client: any YouTubeGatewayReadClient) async throws -> JSONObject {
    do {
      let encoded: Data
      switch request {
      case let .subscriptions(filter, forChannelId, order, parts, maxResults, pageToken):
        let sdkFilter: SubscriptionFilter
        switch filter {
        case .mine: sdkFilter = .mine
        case let .channelId(value): sdkFilter = .channelID(value)
        case let .ids(value): sdkFilter = .ids(value)
        case .mySubscribers: sdkFilter = .mySubscribers
        case .myRecentSubscribers: sdkFilter = .myRecentSubscribers
        }
        var options = SubscriptionListOptions(filter: sdkFilter)
        options.parts = parts.compactMap(SubscriptionPart.init(rawValue:))
        options.forChannelID = forChannelId
        options.order = order.flatMap(SubscriptionOrder.init(rawValue:))
        options.maxResults = maxResults
        options.pageToken = pageToken
        encoded = try JSONEncoder().encode(await client.list(options))
      case let .videos(ids, parts, pageToken):
        encoded = try JSONEncoder().encode(await client.videosList(.init(ids: ids, parts: parts, pageToken: pageToken)))
      case let .channels(selector, parts):
        let options: ChannelListOptions
        switch selector {
        case let .ids(ids): options = .init(ids: ids, parts: parts)
        case let .forHandle(handle): options = .init(forHandle: handle, parts: parts)
        case .mine: options = .init(mine: true, parts: parts)
        }
        encoded = try JSONEncoder().encode(await client.channelsList(options))
      case let .playlistItems(selector, parts, maxResults, pageToken):
        let options: PlaylistItemsListOptions
        switch selector {
        case let .playlistId(id): options = .init(playlistID: id, maxResults: maxResults, pageToken: pageToken, parts: parts)
        case let .ids(ids): options = .init(ids: ids, maxResults: maxResults, pageToken: pageToken, parts: parts)
        }
        encoded = try JSONEncoder().encode(await client.playlistItemsList(options))
      }
      guard case let .object(result) = try JSONDecoder().decode(RielaCore.JSONValue.self, from: encoded) else {
        throw AdapterExecutionError(.invalidOutput, "YouTube gateway returned a non-object page")
      }
      return result
    } catch let error as AdapterExecutionError {
      throw error
    } catch {
      try handleYouTubeRequestError(error)
      throw AdapterExecutionError(.providerError, youtubeFailureMessage("YouTube request failed", error))
    }
  }
}
#endif

extension BuiltinWorkflowAddonResolver {
  static let youtubeGatewayReadRegistration = BuiltinAddonHandlerRegistration(name: YouTubeGatewayReadEngine.addonName) { resolver, input, context in
    try await resolver.executeYouTubeGatewayRead(input, context: context)
  }

  #if canImport(YouTubeGatewayCore)
  func executeYouTubeGatewayRead(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext,
    makeClient: @Sendable ([String: String]) throws -> any YouTubeGatewayReadClient = { try YouTubeClient.fromEnvironment($0) }
  ) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported YouTube gateway version")
    }
    let config = input.addon.config ?? [:]
    try YouTubeGatewayReadEngine.requestShapeIssue(config: config, inputs: input.addon.inputs)
    guard case let .string(operation)? = config["operation"] else {
      throw AdapterExecutionError(.policyBlocked, "YouTube gateway operation is required")
    }
    let arguments = try BuiltinGatewayJSONRequest.renderedArguments(config: config, variables: addonVariables(for: input), addonName: input.addon.name)
    let request = try YouTubeGatewayReadEngine.parse(operation: operation, arguments: arguments)
    let allowed: Set<String> = ["YOUTUBE_GATEWAY_TOKEN_STORE_JSON", "YOUTUBE_GATEWAY_ACCESS_TOKEN"]
    let bindings = input.addon.env ?? [:]
    guard Set(bindings.keys).isSubset(of: allowed) else {
      throw AdapterExecutionError(.policyBlocked, "YouTube gateway env target is not supported")
    }
    let resolved = try resolveAddonEnvironment(bindings, runtimeEnvironment: environment)
    let credentials = resolved.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.value.isEmpty }
    guard !credentials.isEmpty, let client = try? makeClient(credentials) else {
      throw AdapterExecutionError(.policyBlocked, "Set YOUTUBE_GATEWAY_ACCESS_TOKEN or YOUTUBE_GATEWAY_TOKEN_STORE_JSON")
    }
    let data = try await YouTubeGatewayReadEngine.execute(request, client: client)
    let payload: JSONObject = ["status": .string("ok"), "addon": .string(input.addon.name), "stepId": .string(input.stepId),
                              "operation": .string(operation), "data": .object(data)]
    guard try JSONEncoder().encode(payload).count <= 8_000_000 else {
      throw AdapterExecutionError(.invalidOutput, "YouTube gateway output exceeds 8 MB")
    }
    return .init(provider: "youtube-gateway", model: input.addon.name, promptText: "", completionPassed: true, payload: payload)
  }
  #else
  func executeYouTubeGatewayRead(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported YouTube gateway version")
    }
    let config = input.addon.config ?? [:]
    try YouTubeGatewayReadEngine.requestShapeIssue(config: config, inputs: input.addon.inputs)
    guard case let .string(operation)? = config["operation"] else {
      throw AdapterExecutionError(.policyBlocked, "YouTube gateway operation is required")
    }
    let arguments = try BuiltinGatewayJSONRequest.renderedArguments(config: config, variables: addonVariables(for: input), addonName: input.addon.name)
    _ = try YouTubeGatewayReadEngine.parse(operation: operation, arguments: arguments)
    throw AdapterExecutionError(.policyBlocked, "youtube-gateway requires macOS")
  }
  #endif
}
