import Foundation
import RielaAddonSupport
import RielaCore
import XCTest
@testable import RielaCLI
#if canImport(YouTubeGatewayCore)
import YouTubeGatewayCore

private actor YouTubeFixtureTransport: HTTPTransport {
  private let failingResource: String?
  private let failureStatus: Int
  private let failureBody: String
  private let omitMaxres: Bool
  private let filterFixture: Bool
  private(set) var urls: [URL] = []

  init(failingResource: String? = nil, failureStatus: Int = 503, failureBody: String = #"{"error":{"errors":[{"reason":"backendError"}]}}"#, omitMaxres: Bool = false, filterFixture: Bool = false) {
    self.failingResource = failingResource
    self.failureStatus = failureStatus
    self.failureBody = failureBody
    self.omitMaxres = omitMaxres
    self.filterFixture = filterFixture
  }

  func send(_ request: URLRequest) async throws -> HTTPResult {
    guard let url = request.url else { throw URLError(.badURL) }
    urls.append(url)
    let resource = url.pathComponents.last ?? ""
    if resource == failingResource { return HTTPResult(data: Data(failureBody.utf8), status: failureStatus) }
    var body: String
    switch resource {
    case "channels":
      let handle = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "forHandle" })?.value
      switch handle {
      case "older": body = #"{"items":[{"id":"CHolder","contentDetails":{"relatedPlaylists":{"uploads":"UUolder"}}}]}"#
      case "newer": body = #"{"items":[{"id":"CHnewer","contentDetails":{"relatedPlaylists":{"uploads":"UUnewer"}}}]}"#
      default: body = #"{"items":[{"id":"UCFBqEEd6cWtdCIEO0mHMluA","contentDetails":{"relatedPlaylists":{"uploads":"UUuploads"}}}]}"#
      }
    case "playlistItems":
      let playlist = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "playlistId" })?.value
      let pageToken = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pageToken" })?.value
      switch playlist {
      case "LL" where pageToken == nil:
        body = #"{"nextPageToken":"page2","items":["# +
          #"{"snippet":{"publishedAt":"2026-10-31T01:00:00Z"},"contentDetails":{"videoId":"8QxKwYOyUaE","videoPublishedAt":"2026-10-28T15:02:55Z"}},"# +
          #"{"snippet":{"publishedAt":"2026-10-31T00:30:00Z"},"contentDetails":{"videoId":"8QxKwYOyUaE"}}]}"#
      case "LL":
        body = #"{"nextPageToken":"page3","items":["# +
          #"{"snippet":{"publishedAt":"2026-10-30T23:00:00Z"},"contentDetails":{"videoId":"oldVideo123","videoPublishedAt":"2026-10-01T00:00:00Z"}},"# +
          #"{"snippet":{"publishedAt":"2026-10-29T00:00:00Z"},"contentDetails":{"videoId":"videoold001"}}]}"#
      case "UUolder": body = #"{"items":[{"contentDetails":{"videoId":"videoold001","videoPublishedAt":"2026-10-20T00:00:00Z"}}]}"#
      case "UUnewer": body = #"{"items":[{"contentDetails":{"videoId":"videonew001","videoPublishedAt":"2026-10-28T00:00:00Z"}}]}"#
      default: body = #"{"items":[{"contentDetails":{"videoId":"8QxKwYOyUaE","videoPublishedAt":"2026-10-28T15:02:55Z"}},{"contentDetails":{"videoId":"oldVideo123","videoPublishedAt":"2026-10-01T00:00:00Z"}}]}"#
      }
    case "videos":
      body = #"""
      {"items":[{
        "id":"8QxKwYOyUaE",
        "snippet":{
          "title":"Fixture title","description":"Description",
          "channelId":"UCFBqEEd6cWtdCIEO0mHMluA","channelTitle":"Fixture channel",
          "publishedAt":"2026-10-28T15:02:55Z","liveBroadcastContent":"none",
          "defaultAudioLanguage":"ja","tags":["one"],
          "thumbnails":{"maxres":{"url":"https://img/max.jpg"},"high":{"url":"https://img/high.jpg"}}
        },
        "contentDetails":{"duration":"PT13M44S"}
      },{
        "id":"oldVideo123",
        "snippet":{"title":"Explicit old video","publishedAt":"2026-10-01T00:00:00Z"},
        "contentDetails":{"duration":"PT0S"}
      },{
        "id":"videoold001",
        "snippet":{"title":"Older channel video","publishedAt":"2026-10-20T00:00:00Z"}
      },{
        "id":"videonew001",
        "snippet":{"title":"Newer channel video","publishedAt":"2026-10-28T00:00:00Z"}
      }]}
      """#
    default: body = #"{"items":[]}"#
    }
    if filterFixture && resource == "videos" {
      body = #"""
      {"items":[
        {"id":"8QxKwYOyUaE","snippet":{"liveBroadcastContent":"live"},"contentDetails":{"duration":"PT9999S"}},
        {"id":"oldVideo123","snippet":{"liveBroadcastContent":"upcoming"},"contentDetails":{"duration":"PT300S"}},
        {"id":"videonew001","snippet":{"liveBroadcastContent":"none","publishedAt":"2026-10-28T00:00:00Z"},"contentDetails":{"duration":"PT900S"}},
        {"id":"videoold001","snippet":{"liveBroadcastContent":"none","publishedAt":"2026-10-20T00:00:00Z"}}
      ]}
      """#
    }
    if omitMaxres { body = body.replacingOccurrences(of: #""maxres":{"url":"https://img/max.jpg"},"#, with: "") }
    return HTTPResult(data: Data(body.utf8), status: 200)
  }

  func recordedURLs() -> [URL] { urls }
}

private struct YouTubeFilterCase {
  let filters: JSONObject
  let expectedIDs: [String]
  let excluded: JSONObject?
}

private struct YouTubeGatewayFailureFixture {
  let status: Int
  let body: String
  let expectedMessage: String
}

private struct FailingYouTubeCollectionClient: YouTubeCollectionClient {
  enum Failure: Sendable { case configuration, cancellation }
  let failure: Failure

  func videosList(_ options: VideoListOptions) async throws -> VideoPage { try throwFailure() }
  func channelsList(_ options: ChannelListOptions) async throws -> ChannelPage { try throwFailure() }
  func playlistItemsList(_ options: PlaylistItemsListOptions) async throws -> PlaylistItemsPage { try throwFailure() }

  private func throwFailure() throws -> Never {
    switch failure {
    case .configuration: throw GatewayError("No refresh token; run auth login")
    case .cancellation: throw CancellationError()
    }
  }
}

final class YouTubeCollectionTests: XCTestCase {
  func testOptionsValidationAndReferenceParsingPassThrough() throws {
    XCTAssertNoThrow(try YouTubeCollectionOptions(["videos": .array([.string("8QxKwYOyUaE")]), "maxPerChannel": .integer(50)]))
    XCTAssertThrowsError(try YouTubeCollectionOptions(["videos": .array([.string("8QxKwYOyUaE")]), "maxPerChannel": .integer(51)]))
    XCTAssertThrowsError(try YouTubeCollectionOptions(["channels": .array([.string("@handle")]), "publishedAfter": .string("2026-10-20")]))
    XCTAssertThrowsError(try YouTubeCollectionOptions(["videos": .array([.string("x")]), "unexpected": .bool(true)]))
    XCTAssertThrowsError(try YouTubeCollectionOptions(["videos": .string("8QxKwYOyUaE")]))
    XCTAssertThrowsError(try YouTubeCollectionOptions(["videos": .array([.string(" \n\t ")])]))
    XCTAssertThrowsError(try YouTubeCollectionOptions(["channels": .array([.string(" \n\t ")])]))
    XCTAssertEqual(YouTubeVideoReference.parse("https://www.youtube.com/watch?v=8QxKwYOyUaE&t=482s"), "8QxKwYOyUaE")
    XCTAssertEqual(YouTubeVideoReference.parse("https://youtu.be/8QxKwYOyUaE?t=10"), "8QxKwYOyUaE")
    XCTAssertEqual(YouTubeChannelReference.parse("https://www.youtube.com/@somebody/videos"), .handle("somebody"))
  }

  func testChannelHandleSequenceFilteringDedupeAndOutputContract() async throws {
    let options = try YouTubeCollectionOptions([
      "videos": .array([.string("  https://www.youtube.com/watch?v=8QxKwYOyUaE&t=482s  "), .string("oldVideo123"), .string("bad-ref")]),
      "channels": .array([.string(" @handle "), .string("UCFBqEEd6cWtdCIEO0mHMluA")]),
      "publishedAfter": .string("2026-10-20T00:00:00.123+09:00"), "maxPerChannel": .integer(5)
    ])
    let transport = YouTubeFixtureTransport()
    let collector = YouTubeCollection(options: options) { environment in
      try YouTubeClient.fromEnvironment(environment, transport: transport)
    }
    let result = try await collector.collect(environment: ["YOUTUBE_GATEWAY_ACCESS_TOKEN": "fake-token"])
    XCTAssertEqual(Set(result.keys), Set(["videos", "failures", "requests"]))
    XCTAssertEqual(result["requests"], .integer(4))
    guard case let .array(videos)? = result["videos"], case let .object(video)? = videos.first else {
      return XCTFail("expected video payload")
    }
    XCTAssertEqual(videos.count, 2)
    XCTAssertEqual(video["id"], .string("8QxKwYOyUaE"))
    XCTAssertEqual(video["title"], .string("Fixture title"))
    XCTAssertEqual(video["durationSeconds"], .integer(824))
    XCTAssertEqual(video["thumbnailUrl"], .string("https://img/max.jpg"))
    XCTAssertEqual(video["defaultAudioLanguage"], .string("ja"))
    XCTAssertEqual(video["tags"], .array([.string("one")]))
    XCTAssertEqual(video["sources"], .array([.string("video"), .string("channel:UCFBqEEd6cWtdCIEO0mHMluA")]))
    guard case let .object(explicitOld)? = videos.last else { return XCTFail("expected old explicit video") }
    XCTAssertEqual(explicitOld["publishedAt"], .string("2026-10-01T00:00:00Z"))
    XCTAssertEqual(explicitOld["sources"], .array([.string("video")]))
    guard case let .array(failures)? = result["failures"] else { return XCTFail("expected failures") }
    XCTAssertEqual(failures.count, 1)
    guard case let .object(referenceFailure) = failures[0] else { return XCTFail("expected reference failure") }
    XCTAssertEqual(referenceFailure["stage"], .string("reference"))
    let urls = await transport.recordedURLs()
    XCTAssertEqual(urls.map(\.pathComponents.last), ["channels", "playlistItems", "channels", "videos"])
    XCTAssertEqual(URLComponents(url: urls[0], resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "forHandle" })?.value, "handle")
    XCTAssertEqual(URLComponents(url: urls[1], resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "playlistId" })?.value, "UUuploads")
    XCTAssertEqual(URLComponents(url: urls[1], resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "maxResults" })?.value, "5")
    guard let lastURL = urls.last else { return XCTFail("expected videos.list request") }
    XCTAssertTrue(URLComponents(url: lastURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "part" })?.value?.contains("liveStreamingDetails") == true)
  }

  func testLikedOptionValidation() throws {
    XCTAssertNoThrow(try YouTubeCollectionOptions(["likedAfter": .string("2026-10-30T15:00:00Z")]))
    XCTAssertNoThrow(try YouTubeCollectionOptions(["likedAfter": .string("2026-10-30T15:00:00Z"), "maxLiked": .integer(500)]))
    for input: JSONObject in [
      ["likedAfter": .string("2026-10-30")], ["likedAfter": .null], ["likedAfter": .integer(1)],
      ["likedAfter": .string("2026-10-30T15:00:00Z"), "maxLiked": .integer(0)],
      ["likedAfter": .string("2026-10-30T15:00:00Z"), "maxLiked": .integer(501)],
      ["maxLiked": .integer(10)]
    ] {
      XCTAssertThrowsError(try YouTubeCollectionOptions(input)) {
        XCTAssertEqual(($0 as? AdapterExecutionError)?.code, .invalidInput)
      }
    }
  }

  func testLikedVideosStopAtLikedAfterAcrossPagesAndMergeSources() async throws {
    let options = try YouTubeCollectionOptions([
      "channels": .array([.string("@newer")]), "publishedAfter": .string("2026-10-20T00:00:00Z"),
      "likedAfter": .string("2026-10-30T15:00:00Z")
    ])
    let transport = YouTubeFixtureTransport()
    let collector = YouTubeCollection(options: options) { environment in
      try YouTubeClient.fromEnvironment(environment, transport: transport)
    }
    let result = try await collector.collect(environment: ["YOUTUBE_GATEWAY_ACCESS_TOKEN": "fake-token"])
    guard case let .array(videos)? = result["videos"] else { return XCTFail("expected videos") }
    let records = videos.compactMap { if case let .object(video) = $0 { return video }; return nil }
    XCTAssertEqual(records.map { $0["id"] }, [.string("8QxKwYOyUaE"), .string("oldVideo123"), .string("videonew001")])
    XCTAssertEqual(records[0]["likedAt"], .string("2026-10-31T01:00:00Z"))
    XCTAssertEqual(records[0]["sources"], .array([.string("liked")]))
    XCTAssertEqual(records[1]["likedAt"], .string("2026-10-30T23:00:00Z"))
    XCTAssertNil(records[2]["likedAt"])
    let urls = await transport.recordedURLs()
    let likedPages = urls.filter {
      URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "playlistId" })?.value == "LL"
    }
    XCTAssertEqual(likedPages.count, 2)
    XCTAssertEqual(URLComponents(url: likedPages[1], resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pageToken" })?.value, "page2")
  }

  func testMaxLikedCapsCollection() async throws {
    let options = try YouTubeCollectionOptions(["likedAfter": .string("2026-10-01T00:00:00Z"), "maxLiked": .integer(1)])
    let transport = YouTubeFixtureTransport()
    let collector = YouTubeCollection(options: options) { environment in
      try YouTubeClient.fromEnvironment(environment, transport: transport)
    }
    let result = try await collector.collect(environment: ["YOUTUBE_GATEWAY_ACCESS_TOKEN": "fake-token"])
    guard case let .array(videos)? = result["videos"] else { return XCTFail("expected videos") }
    XCTAssertEqual(videos.count, 1)
    let urls = await transport.recordedURLs()
    XCTAssertEqual(urls.map(\.pathComponents.last), ["playlistItems", "videos"])
    XCTAssertEqual(URLComponents(url: urls[0], resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "maxResults" })?.value, "1")
  }

  func testFilterOptionValidation() throws {
    let base: JSONObject = ["videos": .array([.string("8QxKwYOyUaE")])]
    for value: JSONValue in [.integer(0), .integer(604_801), .string("600"), .number(600.5), .null, .bool(true)] {
      var input = base
      input["maxDurationSeconds"] = value
      XCTAssertThrowsError(try YouTubeCollectionOptions(input)) {
        XCTAssertEqual(($0 as? AdapterExecutionError)?.code, .invalidInput)
      }
    }
    for value: JSONValue in [.string("true"), .null, .integer(1)] {
      var input = base
      input["excludeLive"] = value
      XCTAssertThrowsError(try YouTubeCollectionOptions(input)) {
        XCTAssertEqual(($0 as? AdapterExecutionError)?.code, .invalidInput)
      }
    }
    for value: Int64 in [1, 604_800] {
      var input = base
      input["maxDurationSeconds"] = .integer(value)
      XCTAssertNoThrow(try YouTubeCollectionOptions(input))
    }
  }

  func testOrderedFiltersAndDefaultOutput() async throws {
    let base: JSONObject = ["videos": .array([.string("8QxKwYOyUaE"), .string("oldVideo123")]),
      "channels": .array([.string("@newer"), .string("@older")])]
    let cases: [YouTubeFilterCase] = [
      .init(filters: [:], expectedIDs: ["8QxKwYOyUaE", "oldVideo123", "videonew001", "videoold001"], excluded: nil),
      .init(filters: ["excludeLive": .bool(false)], expectedIDs: ["8QxKwYOyUaE", "oldVideo123", "videonew001", "videoold001"], excluded: nil),
      .init(filters: ["excludeLive": .bool(true)], expectedIDs: ["videonew001", "videoold001"],
        excluded: ["count": .integer(2), "live": .array([.string("8QxKwYOyUaE"), .string("oldVideo123")]), "duration": .array([])]),
      .init(filters: ["maxDurationSeconds": .integer(600)], expectedIDs: ["oldVideo123", "videoold001"],
        excluded: ["count": .integer(2), "live": .array([]), "duration": .array([.string("8QxKwYOyUaE"), .string("videonew001")])]),
      .init(filters: ["excludeLive": .bool(true), "maxDurationSeconds": .integer(600)], expectedIDs: ["videoold001"],
        excluded: ["count": .integer(3), "live": .array([.string("8QxKwYOyUaE"), .string("oldVideo123")]), "duration": .array([.string("videonew001")])]),
      .init(filters: ["maxDurationSeconds": .integer(604_800)], expectedIDs: ["8QxKwYOyUaE", "oldVideo123", "videonew001", "videoold001"],
        excluded: ["count": .integer(0), "live": .array([]), "duration": .array([])])
    ]
    for fixture in cases {
      let options = try YouTubeCollectionOptions(base.merging(fixture.filters) { _, new in new })
      let transport = YouTubeFixtureTransport(filterFixture: true)
      let collector = YouTubeCollection(options: options) { environment in
        try YouTubeClient.fromEnvironment(environment, transport: transport)
      }
      let result = try await collector.collect(environment: ["YOUTUBE_GATEWAY_ACCESS_TOKEN": "fake-token"])
      guard case let .array(videos)? = result["videos"] else { return XCTFail("expected videos") }
      XCTAssertEqual(videos.compactMap { value -> String? in
        guard case let .object(record) = value, case let .string(id)? = record["id"] else { return nil }
        return id
      }, fixture.expectedIDs)
      XCTAssertEqual(result["excluded"], fixture.excluded.map(JSONValue.object))
      XCTAssertEqual(result["requests"], .integer(5))
    }
  }

  func testDurationParsingTable() {
    let cases: [(String?, Int?)] = [("PT13M44S", 824), ("PT1H2M3S", 3_723), ("P1DT2H", 93_600), ("PT0S", 0), (nil, nil), ("P", nil),
      ("PT999999999999999999999H", nil), ("garbage", nil)]
    for (value, expected) in cases { XCTAssertEqual(youtubeDuration(value), expected, "duration \(String(describing: value))") }
  }

  func testChannelFailureReturnsPartialVideoDataAndSafeFailure() async throws {
    let options = try YouTubeCollectionOptions([
      "videos": .array([.string("8QxKwYOyUaE")]), "channels": .array([.string("@handle")])
    ])
    let transport = YouTubeFixtureTransport(failingResource: "channels")
    let collector = YouTubeCollection(options: options) { environment in
      try YouTubeClient.fromEnvironment(environment, transport: transport)
    }
    let result = try await collector.collect(environment: ["YOUTUBE_GATEWAY_ACCESS_TOKEN": "fake-token"])
    guard case let .array(videos)? = result["videos"], case let .array(failures)? = result["failures"],
      case let .object(failure)? = failures.first else { return XCTFail("expected partial result") }
    XCTAssertEqual(videos.count, 1)
    XCTAssertEqual(failure["stage"], .string("channel"))
    XCTAssertEqual(failure["message"], .string("YouTube channel lookup failed (provider, 503)"))
    XCTAssertEqual(result["requests"], .integer(2))
  }

  func testWhitespaceCredentialIsUnset() async throws {
    let collector = YouTubeCollection(options: try YouTubeCollectionOptions(["videos": .array([.string("8QxKwYOyUaE")])]))
    do {
      _ = try await collector.collect(environment: ["YOUTUBE_GATEWAY_ACCESS_TOKEN": " \n "])
      XCTFail("expected credential error")
    } catch { XCTAssertTrue(String(describing: error).contains("Set YOUTUBE_GATEWAY_ACCESS_TOKEN")) }
  }

  func testAuthenticationAndQuotaErrorsFailNode() async throws {
    let options = try YouTubeCollectionOptions(["videos": .array([.string("8QxKwYOyUaE")]), "channels": .array([.string("UCFBqEEd6cWtdCIEO0mHMluA")])])
    let failures = [
      YouTubeGatewayFailureFixture(status: 401, body: #"{"error":"invalid_grant"}"#, expectedMessage: "YOUTUBE_GATEWAY_TOKEN_STORE_JSON"),
      YouTubeGatewayFailureFixture(status: 403, body: #"{"error":{"errors":[{"reason":"quotaExceeded"}]}}"#, expectedMessage: "quota exceeded")
    ]
    for failure in failures {
      let transport = YouTubeFixtureTransport(failingResource: "channels", failureStatus: failure.status, failureBody: failure.body)
      let collector = YouTubeCollection(options: options) { environment in
        try YouTubeClient.fromEnvironment(environment, transport: transport)
      }
      do {
        _ = try await collector.collect(environment: ["YOUTUBE_GATEWAY_ACCESS_TOKEN": "fake-token"])
        XCTFail("expected node failure")
      } catch { XCTAssertTrue(String(describing: error).localizedCaseInsensitiveContains(failure.expectedMessage)) }
    }
  }

  func testCredentialConfigurationErrorFailsNodeWithEnvironmentNames() async throws {
    let options = try YouTubeCollectionOptions(["videos": .array([.string("8QxKwYOyUaE")])])
    let collector = YouTubeCollection(options: options) { _ in
      FailingYouTubeCollectionClient(failure: .configuration)
    }
    do {
      _ = try await collector.collect(environment: ["YOUTUBE_GATEWAY_TOKEN_STORE_JSON": "secret-store"])
      XCTFail("expected token configuration error")
    } catch {
      let message = String(describing: error)
      XCTAssertTrue(message.contains("YOUTUBE_GATEWAY_ACCESS_TOKEN"))
      XCTAssertTrue(message.contains("YOUTUBE_GATEWAY_TOKEN_STORE_JSON"))
      XCTAssertFalse(message.contains("secret-store"))
    }
  }

  func testRequestCancellationIsRethrown() async throws {
    let options = try YouTubeCollectionOptions(["videos": .array([.string("8QxKwYOyUaE")])])
    let collector = YouTubeCollection(options: options) { _ in
      FailingYouTubeCollectionClient(failure: .cancellation)
    }
    do {
      _ = try await collector.collect(environment: ["YOUTUBE_GATEWAY_ACCESS_TOKEN": "fake-token"])
      XCTFail("expected cancellation")
    } catch is CancellationError {
      // Expected: request cancellation must not become a per-target failure.
    }
  }

  func testAllFailedRequestsFailAndVideosFailureReportsRequestCount() async throws {
    let options = try YouTubeCollectionOptions(["videos": .array([.string("8QxKwYOyUaE")])])
    let failedTransport = YouTubeFixtureTransport(failingResource: "videos")
    let allFail = YouTubeCollection(options: options) { environment in
      try YouTubeClient.fromEnvironment(environment, transport: failedTransport)
    }
    do {
      _ = try await allFail.collect(environment: ["YOUTUBE_GATEWAY_ACCESS_TOKEN": "fake-token"])
      XCTFail("expected all-failed node error")
    } catch { XCTAssertTrue(String(describing: error).contains("All attempted YouTube requests failed")) }
    let attemptedURLs = await failedTransport.recordedURLs()
    XCTAssertEqual(attemptedURLs.count, 1)

    let partialOptions = try YouTubeCollectionOptions(["videos": .array([.string("8QxKwYOyUaE")]), "channels": .array([.string("UCFBqEEd6cWtdCIEO0mHMluA")])])
    let partialTransport = YouTubeFixtureTransport(failingResource: "videos")
    let partial = YouTubeCollection(options: partialOptions) { environment in
      try YouTubeClient.fromEnvironment(environment, transport: partialTransport)
    }
    let result = try await partial.collect(environment: ["YOUTUBE_GATEWAY_ACCESS_TOKEN": "fake-token"])
    XCTAssertEqual(result["requests"], .integer(3))
    guard case let .array(failures)? = result["failures"], case let .object(failure)? = failures.last else { return XCTFail("expected batch failure") }
    XCTAssertEqual(failure["stage"], .string("videos"))
    XCTAssertEqual(failure["message"], .string("YouTube video lookup failed (provider, 503)"))
  }

  func testVideoIDsOverFiftySplitAcrossBatches() async throws {
    let ids = (0..<51).map { String(format: "v%010d", $0) }
    let options = try YouTubeCollectionOptions(["videos": .array(ids.map(JSONValue.string))])
    let transport = YouTubeFixtureTransport()
    let collector = YouTubeCollection(options: options) { environment in try YouTubeClient.fromEnvironment(environment, transport: transport) }
    let result = try await collector.collect(environment: ["YOUTUBE_GATEWAY_ACCESS_TOKEN": "fake-token"])
    XCTAssertEqual(result["requests"], .integer(2))
    let videoURLs = await transport.recordedURLs().filter { $0.pathComponents.last == "videos" }
    XCTAssertEqual(videoURLs.count, 2)
  }

  func testMissingVideoIDCreatesVideosFailureAndFallbackThumbnailIsChosen() async throws {
    let options = try YouTubeCollectionOptions(["videos": .array([.string("8QxKwYOyUaE"), .string("anotherID12")])])
    let transport = YouTubeFixtureTransport(omitMaxres: true)
    let collector = YouTubeCollection(options: options) { environment in try YouTubeClient.fromEnvironment(environment, transport: transport) }
    let result = try await collector.collect(environment: ["YOUTUBE_GATEWAY_ACCESS_TOKEN": "fake-token"])
    guard case let .array(failures)? = result["failures"], case let .object(failure)? = failures.first else { return XCTFail("expected missing video failure") }
    XCTAssertEqual(failure["target"], .string("anotherID12"))
    XCTAssertEqual(failure["stage"], .string("videos"))
    guard case let .array(videos)? = result["videos"], case let .object(video)? = videos.first else { return XCTFail("expected returned video") }
    XCTAssertEqual(video["thumbnailUrl"], .string("https://img/high.jpg"))
  }

  func testMultipleChannelsAreOrderedNewestFirst() async throws {
    let options = try YouTubeCollectionOptions(["channels": .array([.string("@older"), .string("@newer")])])
    let transport = YouTubeFixtureTransport()
    let collector = YouTubeCollection(options: options) { environment in try YouTubeClient.fromEnvironment(environment, transport: transport) }
    let result = try await collector.collect(environment: ["YOUTUBE_GATEWAY_ACCESS_TOKEN": "fake-token"])
    guard case let .array(videos)? = result["videos"] else { return XCTFail("expected channel videos") }
    XCTAssertEqual(videos.compactMap { value -> String? in
      guard case let .object(object) = value, case let .string(id)? = object["id"] else { return nil }; return id
    }, ["videonew001", "videoold001"])
  }

  func testAdapterRejectsUnexpectedAddonEnvironmentTarget() async throws {
    let input = WorkflowAddonExecutionInput(workflowId: "w", stepId: "s", nodeId: "n",
      addon: .init(name: "riela/youtube-collect", version: "1",
        config: ["options": .object(["videos": .array([.string("8QxKwYOyUaE")])])],
        env: ["UNEXPECTED": .object(["fromEnv": .string("SOURCE")])]))
    do {
      _ = try await BuiltinWorkflowAddonResolver(environment: ["SOURCE": "secret"]).execute(input, context: .init())
      XCTFail("expected unexpected target error")
    } catch { XCTAssertTrue(String(describing: error).contains("only allows")) }
    let unknownConfig = WorkflowAddonExecutionInput(workflowId: "w", stepId: "s", nodeId: "n",
      addon: .init(name: "riela/youtube-collect", version: "1",
        config: ["options": .object(["videos": .array([.string("8QxKwYOyUaE")])]), "unexpected": .bool(true)]))
    do {
      _ = try await BuiltinWorkflowAddonResolver(environment: [:]).execute(unknownConfig, context: .init())
      XCTFail("expected unknown config key error")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput) }
    let nonObjectOptions = WorkflowAddonExecutionInput(workflowId: "w", stepId: "s", nodeId: "n",
      addon: .init(name: "riela/youtube-collect", version: "1", config: ["options": .string("not-an-object")]))
    do {
      _ = try await BuiltinWorkflowAddonResolver(environment: [:]).execute(nonObjectOptions, context: .init())
      XCTFail("expected non-object options error")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput) }
  }

  func testCredentialsAreAllowlistedAndMissingCredentialErrorIsSafe() async throws {
    let options = try YouTubeCollectionOptions(["videos": .array([.string("8QxKwYOyUaE")])])
    let collector = YouTubeCollection(options: options) { _ in throw NSError(domain: "test", code: 1) }
    do {
      _ = try await collector.collect(environment: ["OTHER_SECRET": "secret-value"])
      XCTFail("expected allowlist error")
    } catch { XCTAssertFalse(String(describing: error).contains("secret-value")) }
    do {
      _ = try await collector.collect(environment: [:])
      XCTFail("expected credential error")
    } catch {
      XCTAssertTrue(String(describing: error).contains("YOUTUBE_GATEWAY_ACCESS_TOKEN"))
      XCTAssertFalse(String(describing: error).contains("secret-value"))
    }
  }
}
#else
final class YouTubeCollectionTests: XCTestCase {
  func testMacOSOnlyPolicy() async throws {
    let options = try YouTubeCollectionOptions(["videos": .array([.string("8QxKwYOyUaE")])])
    do {
      _ = try await YouTubeCollection(options: options).collect(environment: [:])
      XCTFail("expected platform policy error")
    } catch { XCTAssertTrue(String(describing: error).contains("requires macOS")) }
  }
}
#endif
