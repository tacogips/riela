import Foundation
@testable import RielaNoteUI
import XCTest

final class RielaNoteMarkdownBlockCacheTests: XCTestCase {
  func testUnchangedMarkdownIsParsedOnce() {
    let cache = RielaNoteMarkdownBlockCache()
    let markdown = "# Title\n\nParagraph body with **bold** text.\n\n- item one\n- item two"

    let first = cache.blocks(for: markdown)
    XCTAssertEqual(cache.parseCount, 1)

    // A re-render with the same body must reuse the cached blocks and not re-parse.
    let second = cache.blocks(for: markdown)
    let third = cache.blocks(for: markdown)
    XCTAssertEqual(cache.parseCount, 1, "identical markdown should skip the parse")
    XCTAssertEqual(first, second)
    XCTAssertEqual(second, third)
  }

  func testDistinctMarkdownParsesPerBody() {
    let cache = RielaNoteMarkdownBlockCache()

    _ = cache.blocks(for: "first body")
    _ = cache.blocks(for: "second body")
    _ = cache.blocks(for: "first body")

    XCTAssertEqual(cache.parseCount, 2, "each distinct body parses once, repeats are cached")
  }

  func testEvictionReparsesEvictedBody() {
    let cache = RielaNoteMarkdownBlockCache(capacity: 2)

    _ = cache.blocks(for: "a")
    _ = cache.blocks(for: "b")
    _ = cache.blocks(for: "c") // evicts "a"
    XCTAssertEqual(cache.parseCount, 3)

    _ = cache.blocks(for: "a") // re-parsed because it was evicted
    XCTAssertEqual(cache.parseCount, 4)
  }
}
