import Foundation
import RielaAddonSupport
import RielaCore
#if canImport(YouTubeGatewayCore)
import YouTubeGatewayCore
#endif

#if canImport(YouTubeGatewayCore)
protocol YouTubeCollectionClient: Sendable {
  func videosList(_ options: VideoListOptions) async throws -> VideoPage
  func channelsList(_ options: ChannelListOptions) async throws -> ChannelPage
  func playlistItemsList(_ options: PlaylistItemsListOptions) async throws -> PlaylistItemsPage
}

extension YouTubeClient: YouTubeCollectionClient {}

private struct YouTubeChannelUpload {
  let id: String
  let source: String
  let publishedAt: Date?
}
#endif

struct YouTubeCollectionOptions {
  let videos: [String]
  let channels: [String]
  let publishedAfter: Date?
  let maxPerChannel: Int

  init(_ value: JSONObject) throws {
    guard Set(value.keys).isSubset(of: ["videos", "channels", "publishedAfter", "maxPerChannel"]),
      case let .array(videos) = value["videos"] ?? .array([]),
      videos.allSatisfy({ if case let .string(text) = $0 { return !text.isEmpty }; return false }),
      case let .array(channels) = value["channels"] ?? .array([]),
      channels.allSatisfy({ if case let .string(text) = $0 { return !text.isEmpty }; return false }),
      case let .integer(maximum) = value["maxPerChannel"] ?? .integer(10), (1...50).contains(maximum)
    else { throw youtubeCollectionInvalid() }
    let after: Date?
    switch value["publishedAfter"] {
    case nil, .null?: after = nil
    case let .string(text)?:
      guard let parsed = youtubeInstant(text) else { throw youtubeCollectionInvalid() }
      after = parsed
    default: throw youtubeCollectionInvalid()
    }
    guard !videos.isEmpty || !channels.isEmpty else { throw youtubeCollectionInvalid() }
    self.videos = videos.compactMap { if case let .string(text) = $0 { return text.trimmingCharacters(in: .whitespacesAndNewlines) }; return nil }
    self.channels = channels.compactMap { if case let .string(text) = $0 { return text.trimmingCharacters(in: .whitespacesAndNewlines) }; return nil }
    self.publishedAfter = after
    self.maxPerChannel = Int(maximum)
  }
}

struct YouTubeCollection {
  let options: YouTubeCollectionOptions
#if canImport(YouTubeGatewayCore)
  var makeClient: (@Sendable ([String: String]) throws -> any YouTubeCollectionClient)?
#endif

  #if canImport(YouTubeGatewayCore)
  init(options: YouTubeCollectionOptions, makeClient: @escaping @Sendable ([String: String]) throws -> any YouTubeCollectionClient = {
    try YouTubeClient.fromEnvironment($0)
  }) {
    self.options = options
    self.makeClient = makeClient
  }
  #else
  init(options: YouTubeCollectionOptions) {
    self.options = options
  }
  #endif

  func collect(environment: [String: String]) async throws -> JSONObject {
    #if canImport(YouTubeGatewayCore)
    let allowed = Set(["YOUTUBE_GATEWAY_TOKEN_STORE_JSON", "YOUTUBE_GATEWAY_ACCESS_TOKEN"])
    guard Set(environment.keys).isSubset(of: allowed) else {
      throw AdapterExecutionError(.policyBlocked, "YouTube collection only allows YOUTUBE_GATEWAY_ACCESS_TOKEN and YOUTUBE_GATEWAY_TOKEN_STORE_JSON")
    }
    let trimmedEnvironment = environment.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard trimmedEnvironment.values.contains(where: { !$0.isEmpty }) else {
      throw AdapterExecutionError(.policyBlocked, "Set YOUTUBE_GATEWAY_ACCESS_TOKEN or YOUTUBE_GATEWAY_TOKEN_STORE_JSON")
    }
    guard let makeClient else { throw youtubeCollectionInvalid() }
    let client: any YouTubeCollectionClient
    do { client = try makeClient(trimmedEnvironment) } catch {
      throw AdapterExecutionError(.policyBlocked, "Set YOUTUBE_GATEWAY_ACCESS_TOKEN or YOUTUBE_GATEWAY_TOKEN_STORE_JSON")
    }
    var requests = 0
    var successfulRequests = 0
    var failures: [JSONValue] = []
    var selected: [(String, String)] = []
    var explicitOrder: [String] = []
    var explicitIDs = Set<String>()
    var channelUploads: [YouTubeChannelUpload] = []
    for target in options.videos {
      guard let id = YouTubeVideoReference.parse(target) else {
        failures.append(youtubeFailure(target, "reference", "Unparseable video reference")); continue
      }
      selected.append((id, "video"))
      if explicitIDs.insert(id).inserted { explicitOrder.append(id) }
    }
    let after = options.publishedAfter
    var resolvedChannelIDs = Set<String>()
    for target in options.channels {
      guard let reference = YouTubeChannelReference.parse(target) else {
        failures.append(youtubeFailure(target, "reference", "Unparseable channel reference")); continue
      }
      let channelPage: ChannelPage
      do {
        requests += 1
        switch reference {
        case let .id(id): channelPage = try await client.channelsList(.init(ids: [id], parts: ["snippet", "contentDetails"]))
        case let .handle(handle): channelPage = try await client.channelsList(.init(forHandle: handle, parts: ["snippet", "contentDetails"]))
        }
      } catch {
        try handleYouTubeRequestError(error)
        failures.append(youtubeFailure(target, "channel", youtubeFailureMessage("YouTube channel lookup failed", error))); continue
      }
      successfulRequests += 1
      guard let channel = channelPage.items.first, let channelID = channel.id,
        let uploads = channel.contentDetails?.relatedPlaylists?.uploads else {
        failures.append(youtubeFailure(target, "channel", "Channel uploads playlist was unavailable")); continue
      }
      guard resolvedChannelIDs.insert(channelID).inserted else { continue }
      do {
        requests += 1
        let page = try await client.playlistItemsList(.init(playlistID: uploads, maxResults: options.maxPerChannel,
          parts: ["snippet", "contentDetails"]))
        successfulRequests += 1
        for item in page.items {
          guard let id = item.contentDetails?.videoId ?? item.snippet?.resourceId?.videoId else { continue }
          let published = (item.contentDetails?.videoPublishedAt ?? item.snippet?.publishedAt).flatMap(youtubeInstant)
          if let after {
            guard let published, published >= after else { continue }
          }
          channelUploads.append(.init(id: id, source: "channel:" + channelID, publishedAt: published))
        }
      } catch {
        try handleYouTubeRequestError(error)
        failures.append(youtubeFailure(target, "uploads", youtubeFailureMessage("YouTube uploads lookup failed", error)))
      }
    }
    selected.append(contentsOf: channelUploads.enumerated().sorted { lhs, rhs in
      let leftDate = lhs.element.publishedAt ?? .distantPast
      let rightDate = rhs.element.publishedAt ?? .distantPast
      return leftDate == rightDate ? lhs.offset < rhs.offset : leftDate > rightDate
    }.map { ($0.element.id, $0.element.source) })
    var sourcesByID: [String: [String]] = [:]
    var orderedIDs: [String] = []
    for (id, source) in selected {
      if sourcesByID[id] == nil { orderedIDs.append(id); sourcesByID[id] = [] }
      if sourcesByID[id]?.contains(source) == false { sourcesByID[id, default: []].append(source) }
    }
    var records: [String: JSONObject] = [:]
    for batchStart in stride(from: 0, to: orderedIDs.count, by: 50) {
      let ids = Array(orderedIDs[batchStart..<min(batchStart + 50, orderedIDs.count)])
      do {
        requests += 1
        let page = try await client.videosList(.init(ids: ids, parts: ["snippet", "contentDetails", "liveStreamingDetails"]))
        successfulRequests += 1
        for video in page.items {
          guard let id = video.id else { continue }
          let snippet = video.snippet
          let thumbs = snippet?.thumbnails ?? [:]
          let thumbnail = ["maxres", "standard", "high", "medium", "default"].compactMap { thumbs[$0]?.url }.first
          records[id] = [
            "id": .string(id), "url": .string("https://www.youtube.com/watch?v=" + id),
            "title": snippet?.title.map(JSONValue.string) ?? .null,
            "description": snippet?.description.map(JSONValue.string) ?? .null,
            "channelId": snippet?.channelId.map(JSONValue.string) ?? .null,
            "channelTitle": snippet?.channelTitle.map(JSONValue.string) ?? .null,
            "publishedAt": snippet?.publishedAt.map(JSONValue.string) ?? .null,
            "durationSeconds": youtubeDuration(video.contentDetails?.duration).map { .integer(Int64($0)) } ?? .null,
            "thumbnailUrl": thumbnail.map(JSONValue.string) ?? .null,
            "liveBroadcastContent": snippet?.liveBroadcastContent.map(JSONValue.string) ?? .null,
            "defaultAudioLanguage": snippet?.defaultAudioLanguage.map(JSONValue.string) ?? .null,
            "tags": .array((snippet?.tags ?? []).map(JSONValue.string)),
            "sources": .array(sourcesByID[id, default: []].map(JSONValue.string))
          ]
        }
        for id in ids where records[id] == nil {
          failures.append(youtubeFailure(id, "videos", "Video was not returned; it may be private or deleted"))
        }
      } catch {
        try handleYouTubeRequestError(error)
        failures.append(youtubeFailure(ids.joined(separator: ","), "videos", youtubeFailureMessage("YouTube video lookup failed", error)))
      }
    }
    if requests > 0 && successfulRequests == 0 {
      throw AdapterExecutionError(.policyBlocked, "All attempted YouTube requests failed")
    }
    let channelIDs = orderedIDs.filter { !explicitIDs.contains($0) }
    let orderedChannelIDs = channelIDs.enumerated().sorted { lhs, rhs in
      let leftDate = records[lhs.element]?["publishedAt"].flatMap { value -> Date? in
        if case let .string(text) = value { return youtubeInstant(text) }; return nil
      } ?? .distantPast
      let rightDate = records[rhs.element]?["publishedAt"].flatMap { value -> Date? in
        if case let .string(text) = value { return youtubeInstant(text) }; return nil
      } ?? .distantPast
      return leftDate == rightDate ? lhs.offset < rhs.offset : leftDate > rightDate
    }.map(\.element)
    return ["videos": .array((explicitOrder + orderedChannelIDs).compactMap { records[$0].map(JSONValue.object) }),
      "failures": .array(failures), "requests": .integer(Int64(requests))]
    #else
    _ = environment
    throw AdapterExecutionError(.policyBlocked, "youtube-gateway requires macOS")
    #endif
  }
}

#if canImport(YouTubeGatewayCore)
private func handleYouTubeRequestError(_ error: Error) throws {
  guard let error = error as? GatewayError else { return }
  switch error.kind {
  case .authentication:
    throw AdapterExecutionError(.policyBlocked, "YouTube authentication failed; check YOUTUBE_GATEWAY_ACCESS_TOKEN or YOUTUBE_GATEWAY_TOKEN_STORE_JSON")
  case .quotaExceeded:
    throw AdapterExecutionError(.policyBlocked, "YouTube API quota exceeded")
  default: break
  }
}

private func youtubeFailureMessage(_ message: String, _ error: Error) -> String {
  guard let error = error as? GatewayError else { return message }
  let status = error.status.map(String.init) ?? "unknown status"
  return "\(message) (\(error.kind.rawValue), \(status))"
}
#endif

func youtubeDuration(_ value: String?) -> Int? {
  guard let value, value.first == "P" else { return nil }
  let pattern = #"^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$"#
  guard let regex = try? NSRegularExpression(pattern: pattern),
    let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
  guard (1...4).contains(where: { match.range(at: $0).location != NSNotFound }) else { return nil }
  let parts = (1...4).map { index -> Int? in
    guard match.range(at: index).location != NSNotFound,
      let range = Range(match.range(at: index), in: value) else { return 0 }
    return Int(value[range])
  }
  guard let days = parts[0], let hours = parts[1], let minutes = parts[2], let seconds = parts[3] else { return nil }
  let (daySeconds, dayOverflow) = days.multipliedReportingOverflow(by: 86_400)
  let (hourSeconds, hourOverflow) = hours.multipliedReportingOverflow(by: 3_600)
  let (minuteSeconds, minuteOverflow) = minutes.multipliedReportingOverflow(by: 60)
  let (firstSum, firstOverflow) = daySeconds.addingReportingOverflow(hourSeconds)
  let (secondSum, secondOverflow) = firstSum.addingReportingOverflow(minuteSeconds)
  let (total, totalOverflow) = secondSum.addingReportingOverflow(seconds)
  guard !dayOverflow, !hourOverflow, !minuteOverflow, !firstOverflow, !secondOverflow, !totalOverflow else { return nil }
  return total
}

func youtubeInstant(_ value: String) -> Date? {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

private func youtubeFailure(_ target: String, _ stage: String, _ message: String) -> JSONValue {
  .object(["target": .string(target), "stage": .string(stage), "message": .string(message)])
}

func youtubeCollectionInvalid() -> AdapterExecutionError {
  .init(.invalidInput, "invalid YouTube collection configuration")
}
