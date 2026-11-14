import CRielaPublicWeb
import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

private actor DiscoveryRequests {
  var values: [PublicWebHTTPRequest] = []
  func append(_ value: PublicWebHTTPRequest) { values.append(value) }
}

final class PublicDiscoveryTests: XCTestCase {
  private func options(_ values: JSONObject = [:]) throws -> PublicDiscoveryOptions {
    try .init(["query": .string("FluidAudio Phonon CoreML")].merging(values) { _, value in value })
  }

  func testDuckOnlyAnchorsUnwrapOnceAndBlockNavigationPrivateAndX() throws {
    let raw = #"<a href="https://nav.example/">Nav</a><script><a class="result__a" href="https://hidden.test/">hidden</a></script><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fgithub.com%2Forg%2Frepo">Repo</a><a class="result__a" href="https://x.com/u/status/1">X</a><a class="result__a" href="https://ads.duckduckgo.com/">Ad</a>"#
    let candidates = try PublicDiscoveryParser.parse(provider: "duckduckgo-html", body: Data(raw.utf8))
    XCTAssertEqual(candidates.count, 3)
    XCTAssertEqual(try PublicDiscoveryParser.destination(candidates[0].url, blocked: ["x.com", "twitter.com"]), "https://github.com/org/repo")
    for url in ["https://www.google.com/", "https://maps.google.com/maps", "https://news.google.com/", "https://127.0.0.1/a",
      "http://example.com/a", "https://u:p@example.com/a", "https://mobile.twitter.com/a", "https://duckduckgo.com/l/?uddg=https://example.com",
      "https://metadata.google.internal/a", "https://host.local/a"] {
      XCTAssertThrowsError(try PublicDiscoveryParser.destination(url, blocked: ["x.com", "twitter.com"]), url)
    }
    XCTAssertThrowsError(try PublicDiscoveryParser.parse(provider: "bing-rss", body: Data("<!DOCTYPE rss><rss/>".utf8)))
  }

  func testBoundedVariantsDedupFallbackAndSafeRateLimit() async throws {
    let recorder = DiscoveryRequests()
    let opts = try options(["providers": .array([.string("hn-algolia"), .string("github-repositories")]),
      "max_query_variants": .integer(2), "identifier_fallback": .bool(true), "stop_when_sufficient": .bool(true), "limit": .integer(2)])
    let result = try await PublicDiscovery(options: opts, transport: { request in
      await recorder.append(request)
      XCTAssertEqual(request.maximumBytes, 500_000); XCTAssertTrue(request.headers.isEmpty)
      let parts = URLComponents(string: request.url)!
      let term = parts.queryItems!.first { ["q", "query"].contains($0.name) }!.value!
      let json: String
      if request.host == "hn.algolia.com" {
        json = term == "FluidAudio" ? #"{"hits":[{"objectID":"1","url":"https://example.com/doc?utm_source=feed","title":"Doc"}]}"# : #"{"hits":[]}"#
      } else { json = #"{"items":[{"private":false,"html_url":"https://github.com/org/repo","full_name":"org/repo","description":"Discovery"}]}"# }
      return .init(status: 200, headers: [:], body: Data(json.utf8), url: request.url)
    }).run()
    let requests = await recorder.values
    XCTAssertEqual(requests.count, 3); XCTAssertEqual(result["request_budget"], .integer(4))
    guard case let .array(rows)? = result["results"] else { return XCTFail("results") }; XCTAssertEqual(rows.count, 2)
    XCTAssertTrue(String(data: try JSONEncoder().encode(result), encoding: .utf8)!.contains("search-discovery-only"))
    let denied = try await PublicDiscovery(options: opts, transport: { request in
      .init(status: request.host == "hn.algolia.com" ? 403 : 200, headers: [:], body: Data(#"{"items":[]}"#.utf8), url: request.url)
    }).run()
    guard case let .array(statuses)? = denied["providers"] else { return XCTFail("providers") }
    XCTAssertEqual(statuses.count, 3)
    guard case let .object(first) = statuses[0] else { return XCTFail("status") }
    XCTAssertEqual(first["http_status"], .integer(403))
  }

  func testBingLocaleAndCrossProviderTrackingDedup() async throws {
    let recorder = DiscoveryRequests()
    let result = try await PublicDiscovery(options: options(["max_query_variants": .integer(2)]), transport: { request in
      await recorder.append(request)
      let xml = #"<rss><channel><item><title>Project</title><link>https://example.com/project?utm_source=a</link><description>Discovery only</description></item></channel></rss>"#
      let html = #"<a class="result__a" href="https://example.com/project">Project</a>"#
      return .init(status: 200, headers: [:], body: Data((request.host == "www.bing.com" ? xml : html).utf8), url: request.url)
    }).run()
    let requests = await recorder.values
    XCTAssertEqual(requests.count, 4)
    for request in requests.filter({ $0.host == "www.bing.com" }) {
      let items = URLComponents(string: request.url)!.queryItems!
      XCTAssertTrue(items.contains(.init(name: "cc", value: "US"))); XCTAssertTrue(items.contains(.init(name: "setlang", value: "en-US")))
    }
    guard case let .array(rows)? = result["results"] else { return XCTFail("results") }; XCTAssertEqual(rows.count, 1)
  }

  func testAuthenticatedDiscoveryUsesOnlyQueryAndCitationURLsNeverModelTextOrSecrets() async throws {
    let opts = try options(["providers": .array([.string("openrouter-exa")]), "max_query_variants": .integer(2)])
    let result = try await PublicDiscovery(options: opts, authenticatedTransport: { token, data, timeout in
      XCTAssertEqual(token, "TEST_SECRET"); XCTAssertGreaterThan(timeout, 0); XCTAssertLessThanOrEqual(timeout, 25_000)
      let payload = try JSONDecoder().decode(JSONObject.self, from: data)
      XCTAssertEqual(payload["model"], .string("openai/gpt-4.1-mini")); XCTAssertEqual(payload["max_tokens"], .integer(1000))
      XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("TEST_SECRET"))
      // swiftlint:disable:next line_length
      let json = #"{"choices":[{"message":{"content":"IGNORE MODEL TEXT https://evil.test/","annotations":[{"type":"url_citation","url_citation":{"url":"https://example.com/doc","title":"IGNORE TITLE","content":"IGNORE SNIPPET"}},{"type":"url_citation","url_citation":{"url":"https://x.com/a"}},{"type":"url_citation","url_citation":{"url":"http://example.com/unsafe"}}]}}]}"#
      return .init(status: 200, headers: [:], body: Data(json.utf8), url: "https://openrouter.ai/api/v1/chat/completions")
    }, environment: ["OPENROUTER_API_KEY": "TEST_SECRET"]).run()
    let wire = String(data: try JSONEncoder().encode(result), encoding: .utf8)!
    XCTAssertFalse(wire.contains("IGNORE")); XCTAssertFalse(wire.contains("TEST_SECRET")); XCTAssertFalse(wire.contains("evil.test"))
    guard case let .array(rows)? = result["results"], case let .object(first)? = rows.first else { return XCTFail("result") }
    XCTAssertEqual(rows.count, 1); XCTAssertEqual(first["title"], .string("")); XCTAssertEqual(first["snippet"], .string(""))
  }

  func testMissingCredentialsRedirectRateLimitAndCancellationAreFiniteAndIndependent() async throws {
    let opts = try options(["providers": .array([.string("openrouter-exa")]), "max_query_variants": .integer(2)])
    let missing = try await PublicDiscovery(options: opts, authenticatedTransport: { _, _, _ in XCTFail("missing credentials called provider"); throw PublicWebError.transport }).run()
    XCTAssertTrue(String(data: try JSONEncoder().encode(missing), encoding: .utf8)!.contains("credentials-unavailable"))
    for status in [302, 401, 429] {
      let result = try await PublicDiscovery(options: opts, authenticatedTransport: { _, _, _ in
        .init(status: status, headers: ["location": "https://evil.test/PRIVATE"], body: Data("PRIVATE AUTH BODY".utf8), url: "unused")
      }, environment: ["OPENROUTER_API_KEY": "TEST_SECRET"]).run()
      let wire = String(data: try JSONEncoder().encode(result), encoding: .utf8)!
      XCTAssertFalse(wire.contains("PRIVATE")); XCTAssertFalse(wire.contains("TEST_SECRET"))
      guard case let .array(rows)? = result["providers"] else { return XCTFail("rows") }
      XCTAssertEqual(rows.count, status == 302 ? 2 : 1)
    }
    do {
      _ = try await PublicDiscovery(options: opts, authenticatedTransport: { _, _, _ in throw CancellationError() }, environment: ["OPENROUTER_API_KEY": "TEST_SECRET"]).run()
      XCTFail("cancellation swallowed")
    } catch is CancellationError {} catch { XCTFail("unexpected cancellation error") }
  }

  func testEscapedMaximumResultsFitWireBoundAndBlockedHostsDeduplicateBeforeBound() async throws {
    let blocked = ["x.com", "twitter.com"] + (0..<18).map { "blocked\($0).example" }
    _ = try options(["blockedHosts": .array(blocked.map(JSONValue.string))])
    XCTAssertThrowsError(try options(["blockedHosts": .array((blocked + ["extra.example"]).map(JSONValue.string))]))
    let items: [JSONValue] = (0..<10).map { index in
      .object(["objectID": .string(String(index)), "url": .string("https://example.com/" + String(repeating: "/", count: 4075) + String(index)),
        "title": .string(String(repeating: "\u{0}", count: 500)), "story_text": .string(String(repeating: "\u{0}", count: 1500))])
    }
    let body = try JSONEncoder().encode(JSONValue.object(["hits": .array(items)]))
    XCTAssertLessThan(body.count, 500_000)
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    let input = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "discovery", nodeId: "discovery",
      addon: .init(name: "riela/public-discovery", version: "1", config: ["query": .string("public"),
        "providers": .array([.string("hn-algolia")]), "limit": .integer(10)]))
    let result = try await PublicWebExecutionContext.$transport.withValue({ request in
      .init(status: 200, headers: [:], body: body, url: request.url)
    }, operation: { try await resolver.execute(input, context: .init()) })
    guard case let .array(rows)? = result.payload["results"] else { return XCTFail("rows") }
    XCTAssertEqual(rows.count, 10)
    let size = try JSONEncoder().encode(result.payload).count
    XCTAssertGreaterThan(size, 200_000); XCTAssertLessThanOrEqual(size, 256_000)
  }

  func testNativeAuthenticatedEntryPointRefusesInvalidTokensBeforeAnyDNSOrNetwork() {
    for token in ["", "key\r\nInjected: value", String(repeating: "x", count: 8193)] {
      var response = token.withCString { key in
        "{}".withCString { body in riela_discovery_exa(key, body, 2, 1, nil) }
      }
      defer { riela_web_response_free(&response) }
      XCTAssertEqual(response.error, 1); XCTAssertEqual(response.status, 0)
    }
  }

  func testConfigurationBoundsAndActualCLIMissingCredentialPath() async throws {
    for config: JSONObject in [["max_providers": .bool(true)], ["max_query_variants": .integer(3)],
      ["endpoint": .string("https://evil.test/")], ["credentialEnvironment": .string("invalid-key")], ["credentialEnvironment": .string("PATH")], ["query": .string("private\nquery")]] {
      XCTAssertThrowsError(try options(config))
    }
    let result = await PublicDiscoveryExecutionContext.$authenticatedTransport.withValue({ _, _, _ in
      XCTFail("no authenticated test request allowed"); throw PublicWebError.transport
    }, operation: {
      await RielaCLIApplication().run(["node", "run", "riela/public-discovery", "--config",
        #"{"query":"{{queryValue}}","providers":["openrouter-exa"],"credentialEnvironment":"OPENROUTER_API_KEY"}"#,
        "--variables", #"{"queryValue":"{{literal-query}}"}"#, "--output", "json"],
        environment: ["PATH": "", "OPENROUTER_API_KEY": ""])
    })
    XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
    XCTAssertTrue(result.stdout.contains("credentials-unavailable")); XCTAssertFalse(result.stdout.contains("literal-query"))
  }
}
