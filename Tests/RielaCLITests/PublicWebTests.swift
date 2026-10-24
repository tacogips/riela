import CRielaPublicWeb
import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

// TaskLocal test seams intentionally take both a value and operation closure.
// swiftlint:disable multiple_closures_with_trailing_closure
final class PublicWebTests: XCTestCase {
  func testCLIParsesLiteralDataAndCommonPostprocessWithoutNetwork() async throws {
    let body = "<html><title>{{literal}}</title><article>本文</article></html>"
    let config: JSONObject = ["action": .string("parse"), "url": .string("https://example.com"),
      "bodyBase64": .string("{{body}}"), "postprocess": .array([.object(["pick": .string("/title")])])]
    let result = await RielaCLIApplication().run(["node", "run", "riela/public-web", "--config",
      try JSONValue.object(config).compactJSONString(), "--variables",
      try JSONValue.object(["body": .string(Data(body.utf8).base64EncodedString())]).compactJSONString(), "--output", "json"],
      environment: ["HOME": "/tmp", "PATH": ""])
    XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
    let output = try JSONDecoder().decode(NodeRunCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(output.payload["title"], .string("{{literal}}"))
    XCTAssertEqual(output.payload["processed"], .string("{{literal}}"))
  }

  func testResponseActionRejectsAuthBeforeTransportAndPreservesConditionalResponse() async throws {
    try await PublicWebExecutionContext.$transport.withValue({ request in
      XCTAssertEqual(request.headers, ["If-None-Match": "version"])
      return .init(status: 304, headers: ["etag": "version"], body: Data(), url: request.url)
    }) {
      let config: JSONObject = ["action": .string("response"), "url": .string("https://example.com"),
        "headers": .object(["If-None-Match": .string("version")])]
      let result = await RielaCLIApplication().run(["node", "run", "riela/public-web", "--config",
        try JSONValue.object(config).compactJSONString(), "--output", "json"], environment: ["HOME": "/tmp", "PATH": ""])
      XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
      let output = try JSONDecoder().decode(NodeRunCommandResult.self, from: Data(result.stdout.utf8))
      XCTAssertEqual(output.payload["notModified"], .bool(true))
    }
    await PublicWebExecutionContext.$transport.withValue({ _ in XCTFail("auth reached transport"); throw PublicWebError.transport }) {
      let result = await RielaCLIApplication().run(["node", "run", "riela/public-web", "--config",
        #"{"action":"response","url":"https://example.com","headers":{"Authorization":"secret"}}"#,
        "--output", "json"], environment: ["HOME": "/tmp", "PATH": ""])
      XCTAssertNotEqual(result.exitCode, .success)
      XCTAssertFalse(result.stderr.contains("secret"))
    }
  }

  func testAlreadyCancelledNativeCallDoesNotStartDNSOrConnect() throws {
    let cancellation = try XCTUnwrap(riela_web_cancel_create())
    defer { riela_web_cancel_free(cancellation) }
    riela_web_cancel_set(cancellation)
    var response = riela_web_fetch("https://example.com", "example.com", "", 1000, 1000, cancellation)
    defer { riela_web_response_free(&response) }
    XCTAssertEqual(response.error, 5)
    XCTAssertEqual(response.body_length, 0)
  }

  func testRendererResourcesUseInstalledShareAndMissingBundleIsRecoverable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("bin/riela")
    XCTAssertNil(PublicWebResources.browserScript(executable: executable, bundle: root, resources: nil))
    let script = root.appendingPathComponent("share/riela/riela_RielaCLI.bundle/PublicWebBrowser.py")
    try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("# fixture".utf8).write(to: script)
    XCTAssertEqual(PublicWebResources.browserScript(executable: executable, bundle: root, resources: nil), script)
  }

  func testDeepHTMLFailsBeforeRecursiveVisitorExhaustsStack() throws {
    let source = String(repeating: "<div>", count: 160) + "text" + String(repeating: "</div>", count: 160)
    XCTAssertThrowsError(try PublicWebDocument.parse(Data(source.utf8), url: "https://example.com", options: .init())) {
      XCTAssertEqual($0 as? PublicWebError, .oversized)
    }
  }

  func testDiscoveryPolicyRejectsUnsafeLinksBeforeTheyConsumeLinkBudget() async throws {
    let invalid = (0..<60).map { "<a href='http://example.com/article/A\($0)'>unsafe</a>" }.joined()
    let html = "<html><head><title>Index</title></head><body>" + invalid +
      "<a href='https://user:secret@example.com/article/credential'>unsafe</a>" +
      "<a href='https://example.com:444/article/port'>unsafe</a>" +
      "<a href='/article/valid'>article</a></body></html>"
    let reader = PublicWebReader(transport: { request in
      .init(status: 200, headers: [:], body: Data(html.utf8), url: request.url)
    }, browser: { _, _, _, _ in throw PublicWebError.transport })
    let output = try await reader.page(url: "https://example.com", options: .init(), blockedHosts: [],
      metadataOnly: true, includeRaw: false, linkPattern: #"^/article/[A-Za-z0-9]+/?$"#, deadline: nil)
    XCTAssertEqual(output["links"], .array([.string("https://example.com/article/valid")]))
  }

  func testAddressPolicyRejectsLocalReservedAndTransitionNetworks() {
    for ip in ["127.0.0.1", "10.1.2.3", "169.254.169.254", "100.64.0.1", "192.168.1.1",
      "192.0.2.1", "224.0.0.1", "::1", "::ffff:127.0.0.1", "fc00::1", "fe80::1", "2002:7f00:1::", "2001:db8::1"] {
      XCTAssertEqual(ip.withCString { riela_web_public_ip($0) }, 0, ip)
    }
    for ip in ["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111", "::ffff:8.8.8.8"] {
      XCTAssertEqual(ip.withCString { riela_web_public_ip($0) }, 1, ip)
    }
  }

  func testDestinationNormalizesIDNAAndRejectsCredentialsPortsAndBlockedSubdomains() throws {
    XCTAssertEqual(try PublicWebHTTP.destination("https://例え.テスト/a#b", blockedHosts: []).host, "xn--r8jz45g.xn--zckzah")
    for url in ["http://example.com", "https://user:secret@example.com", "https://example.com:444", "https://127.0.0.1", "https://[::1]"] {
      XCTAssertThrowsError(try PublicWebHTTP.destination(url, blockedHosts: []), url)
    }
    XCTAssertThrowsError(try PublicWebHTTP.destination("https://a.example.com", blockedHosts: ["example.com"]))
  }

  func testRedirectToPrivateAddressFailsBeforeSecondTransportCall() async throws {
    do {
      _ = try await PublicWebHTTP.read("https://example.com", transport: { request in
        XCTAssertEqual(request.host, "example.com")
        return .init(status: 302, headers: ["Location": "https://127.0.0.1/secret"], body: Data(), url: request.url)
      })
      XCTFail("redirect accepted")
    } catch { XCTAssertEqual(error as? PublicWebError, .blockedDestination) }
  }

  func testConditionalNotModifiedAndBodyBudget() async throws {
    let response = try await PublicWebHTTP.read("https://example.com", headers: ["If-None-Match": "etag"], transport: { request in
      XCTAssertEqual(request.headers["If-None-Match"], "etag")
      return .init(status: 304, headers: ["ETag": "etag"], body: Data([1]), url: request.url)
    })
    XCTAssertTrue(response.body.isEmpty)
    XCTAssertEqual(response.headers["etag"], "etag")
    do {
      _ = try await PublicWebHTTP.read("https://example.com", maximumBytes: 1, transport: { request in
        .init(status: 200, headers: [:], body: Data([1, 2]), url: request.url)
      })
      XCTFail("oversized body accepted")
    } catch { XCTAssertEqual(error as? PublicWebError, .oversized) }
  }

  func testNativeTransportRejectsLocalDNSWithoutAConnection() async throws {
    do {
      _ = try await PublicWebHTTP.read("https://localhost", timeoutMs: 1000)
      XCTFail("localhost accepted")
    } catch { XCTAssertEqual(error as? PublicWebError, .blockedDestination) }
  }

  func testArticleExtractionIgnoresHiddenNavigationAndDecodesEntities() throws {
    let article = String(repeating: "Article &amp; 本文 ", count: 20)
    let html = "<html><head><title>A &amp; B</title></head><body><nav>navigation</nav><article>\(article)<div hidden>secret</div><script>script secret</script><a href='/story'>story</a></article></body></html>"
    let page = try PublicWebDocument.parse(Data(html.utf8), url: "https://example.com/base", options: .init())
    XCTAssertEqual(page.title, "A & B")
    XCTAssertTrue(page.text.contains("Article & 本文"))
    XCTAssertFalse(page.text.contains("navigation"))
    XCTAssertFalse(page.text.contains("secret"))
    XCTAssertEqual(page.links, ["https://example.com/story"])
  }

  func testMetadataOnlyDoesNotExposeArticleAndDuplicateLinksDoNotExhaustBudget() throws {
    let links = String(repeating: "<a href='/same'>same</a>", count: 100) + "<a href='/other'>other</a>"
    let html = "<html><head><title>fallback</title><meta property='og:title' content='headline'>" +
      "<meta name='description' content='lead'><meta property='article:published_time' content='2026-10-25'>" +
      "<link rel='canonical' href='/canonical'></head><body><article>private article body</article>\(links)</body></html>"
    let page = try PublicWebDocument.parse(Data(html.utf8), url: "https://example.com", options: .init(), metadataOnly: true)
    XCTAssertEqual(page.title, "headline")
    XCTAssertEqual(page.text, "lead")
    XCTAssertEqual(page.publishedAt, "2026-10-25")
    XCTAssertEqual(page.canonical, "/canonical")
    XCTAssertEqual(page.links, ["https://example.com/same", "https://example.com/other"])
  }

  func testExternalEntitiesAreNotExpanded() throws {
    let xml = "<!DOCTYPE root [<!ENTITY leak SYSTEM 'file:///etc/passwd'>]><root>&leak;</root>"
    let bytes = Array(xml.utf8)
    let document = bytes.withUnsafeBytes { riela_web_parse_xml($0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32($0.count)) }
    XCTAssertNil(document)
    if let document { xmlFreeDoc(document) }
    let page = try PublicWebDocument.parse(Data(xml.utf8), url: "https://example.com", options: .init())
    XCTAssertFalse(page.text.contains("root:"))
  }

  func testBlockedHTTPFailureCannotFallBackToBrowser() async throws {
    let reader = PublicWebReader(transport: { _ in throw PublicWebError.blockedDestination }, browser: { _, _, _, _ in
      XCTFail("blocked request reached browser")
      throw PublicWebError.transport
    })
    do {
      _ = try await reader.page(url: "https://example.com", options: .init(), blockedHosts: [], metadataOnly: false, includeRaw: false, linkPattern: nil, deadline: nil)
      XCTFail("blocked request accepted")
    } catch { XCTAssertEqual(error as? PublicWebError, .blockedDestination) }
  }
}

// swiftlint:enable multiple_closures_with_trailing_closure
