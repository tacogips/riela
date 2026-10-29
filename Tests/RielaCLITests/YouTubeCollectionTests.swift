import Foundation
import RielaAddonSupport
import RielaCore
import XCTest
@testable import RielaCLI
#if canImport(YouTubeGatewayCore)
import YouTubeGatewayCore

private actor YouTubeFixtureTransport: HTTPTransport {
  private let failingResource: String?
  private(set) var urls: [URL] = []

  init(failingResource: String? = nil) { self.failingResource = failingResource }

  func send(_ request: URLRequest) async throws -> HTTPResult {
    guard let url = request.url else { throw URLError(.badURL) }
    urls.append(url)
    let resource = url.pathComponents.last ?? ""
    if resource == failingResource { return HTTPResult(data: Data(), status: 503) }
    let body: String
    switch resource {
    case "channels":
      body = #"{"items":[{"id":"UCFBqEEd6cWtdCIEO0mHMluA","contentDetails":{"relatedPlaylists":{"uploads":"UUuploads"}}}]}"#
    case "playlistItems":
      body = #"{"items":[{"contentDetails":{"videoId":"8QxKwYOyUaE","videoPublishedAt":"2026-10-28T15:02:55Z"}},{"contentDetails":{"videoId":"oldVideo123","videoPublishedAt":"2026-10-01T00:00:00Z"}}]}"#
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
      }]}
      """#
    default: body = #"{"items":[]}"#
    }
    return HTTPResult(data: Data(body.utf8), status: 200)
  }

  func recordedURLs() -> [URL] { urls }
}

final class YouTubeCollectionTests: XCTestCase {
  func testOptionsValidationAndReferenceParsingPassThrough() throws {
    XCTAssertNoThrow(try YouTubeCollectionOptions(["videos": .array([.string("8QxKwYOyUaE")]), "maxPerChannel": .integer(50)]))
    XCTAssertThrowsError(try YouTubeCollectionOptions(["videos": .array([.string("8QxKwYOyUaE")]), "maxPerChannel": .integer(51)]))
    XCTAssertThrowsError(try YouTubeCollectionOptions(["channels": .array([.string("@handle")]), "publishedAfter": .string("2026-10-20")]))
    XCTAssertThrowsError(try YouTubeCollectionOptions(["videos": .array([.string("x")]), "unexpected": .bool(true)]))
    XCTAssertEqual(YouTubeVideoReference.parse("https://www.youtube.com/watch?v=8QxKwYOyUaE&t=482s"), "8QxKwYOyUaE")
    XCTAssertEqual(YouTubeVideoReference.parse("https://youtu.be/8QxKwYOyUaE?t=10"), "8QxKwYOyUaE")
    XCTAssertEqual(YouTubeChannelReference.parse("https://www.youtube.com/@somebody/videos"), .handle("somebody"))
  }

  func testChannelHandleSequenceFilteringDedupeAndOutputContract() async throws {
    let options = try YouTubeCollectionOptions([
      "videos": .array([.string("https://www.youtube.com/watch?v=8QxKwYOyUaE&t=482s"), .string("oldVideo123"), .string("bad-ref")]),
      "channels": .array([.string("@handle"), .string("UCFBqEEd6cWtdCIEO0mHMluA")]),
      "publishedAfter": .string("2026-10-20T00:00:00Z"), "maxPerChannel": .integer(5)
    ])
    let transport = YouTubeFixtureTransport()
    let collector = YouTubeCollection(options: options) { environment in
      try YouTubeClient.fromEnvironment(environment, transport: transport)
    }
    let result = try await collector.collect(environment: ["YOUTUBE_GATEWAY_ACCESS_TOKEN": "fake-token"])
    XCTAssertEqual(result["requests"], .integer(5))
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
    let urls = await transport.recordedURLs()
    XCTAssertEqual(urls.map(\.pathComponents.last), ["channels", "playlistItems", "channels", "playlistItems", "videos"])
    XCTAssertEqual(URLComponents(url: urls[0], resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "forHandle" })?.value, "handle")
    XCTAssertEqual(URLComponents(url: urls[1], resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "playlistId" })?.value, "UUuploads")
    XCTAssertEqual(URLComponents(url: urls[1], resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "maxResults" })?.value, "5")
    guard let lastURL = urls.last else { return XCTFail("expected videos.list request") }
    XCTAssertTrue(URLComponents(url: lastURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "part" })?.value?.contains("liveStreamingDetails") == true)
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
    XCTAssertEqual(result["requests"], .integer(2))
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
