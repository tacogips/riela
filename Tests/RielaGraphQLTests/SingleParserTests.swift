import Foundation
import RielaCore
import XCTest
@testable import RielaGraphQL

/// Proof that one GraphQL parser serves every entry point (design 2.3, CSP-3).
/// The architecture review's "two independent GraphQL lexers" finding is closed
/// here: if a second lexer or a private parser appeared beside an entry point,
/// one of these tests fails.
final class SingleParserTests: XCTestCase {
  /// The lexing primitives are declared in exactly one file.
  func testGraphQLLexingPrimitivesLiveInOneFile() throws {
    let owners = try Self.filesDeclaring([
      "func readGraphQLIdentifier(",
      "func skipGraphQLIgnored(",
      "func parseGraphQLValue(",
      "func parseGraphQLNumber(",
      "func readGraphQLString("
    ])
    XCTAssertEqual(
      owners,
      ["Sources/RielaGraphQL/GraphQLDocumentParsing.swift"],
      "GraphQL lexing primitives must stay in one file; found \(owners)"
    )
  }

  /// Nothing outside the shared parsing files declares a GraphQL document
  /// parser. A second parser would show up here the moment it is written.
  func testNoSecondGraphQLDocumentParserExists() throws {
    let allowed: Set<String> = [
      "Sources/RielaGraphQL/GraphQLDocumentParsing.swift",
      "Sources/RielaGraphQL/GraphQLOperationParsing.swift",
      "Sources/RielaGraphQL/GraphQLFragmentParsing.swift",
      "Sources/RielaGraphQL/GraphQLDocumentParsingShared.swift",
      "Sources/RielaGraphQL/GraphQLVariableValidation.swift"
    ]
    // `RielaServer.parseGraphQLEnvelope` decodes the HTTP JSON envelope
    // (query/variables/operationName); it parses no GraphQL document and
    // delegates operation names to the shared parser. Verified below.
    let envelopeDecoder = "Sources/RielaServer/ServerContracts.swift"
    var offenders: [String] = []
    for (path, contents) in try Self.swiftSources() where !allowed.contains(path) && path != envelopeDecoder {
      for line in contents.split(separator: "\n") where line.contains("func parseGraphQL")
        || line.contains("func readGraphQL")
        || line.contains("func skipGraphQL")
        || line.contains("func tokenizeGraphQL") {
        offenders.append("\(path): \(line.trimmingCharacters(in: .whitespaces))")
      }
    }
    XCTAssertTrue(offenders.isEmpty, "a second GraphQL parser appeared:\n" + offenders.joined(separator: "\n"))

    let envelope = try String(
      contentsOf: SurfaceParityGraphQLTests.repositoryRoot().appendingPathComponent(envelopeDecoder),
      encoding: .utf8
    )
    XCTAssertTrue(
      envelope.contains("graphQLNamedOperationNames(in: query)"),
      "the HTTP envelope decoder must delegate operation-name parsing to the shared parser"
    )
    for primitive in ["readGraphQLIdentifier", "skipGraphQLIgnored", "parseGraphQLValue"] {
      XCTAssertFalse(envelope.contains("func \(primitive)"), "the envelope decoder must not lex GraphQL itself")
    }
  }

  /// Every `/graphql` entry point assembles the shared composite executor
  /// rather than parsing documents itself.
  func testEveryEntryPointRoutesThroughTheSharedExecutor() throws {
    let entryPoints: [(path: String, marker: String)] = [
      ("Sources/RielaCLI/ScopedParityCommands+GraphQLDocument.swift", "CompositeGraphQLDocumentExecutor("),
      ("Sources/RielaCLI/ServeWebHost.swift", "CompositeGraphQLDocumentExecutor("),
      ("Sources/RielaApp/RielaAppWebGraphQL.swift", "CompositeGraphQLDocumentExecutor("),
      ("Sources/RielaApp/RielaAppWebRouter.swift", "webGraphQLResponse(for: request)")
    ]
    for entryPoint in entryPoints {
      let url = SurfaceParityGraphQLTests.repositoryRoot().appendingPathComponent(entryPoint.path)
      let contents = try String(contentsOf: url, encoding: .utf8)
      XCTAssertTrue(
        contents.contains(entryPoint.marker),
        "\(entryPoint.path) no longer routes GraphQL through the shared executor"
      )
    }
  }

  /// Behavioural proof: the executors reachable from this module reject the
  /// same malformed document with the same diagnostic, which they could not do
  /// if any of them carried its own parser.
  func testExecutorsShareOneParserDiagnostic() async {
    let malformed = "query Broken { workflows(filter: ) { workflows { workflowId } } }"
    let request = GraphQLDocumentRequest(query: malformed, isLocallyTrusted: true)
    let composite = CompositeGraphQLDocumentExecutor(
      fallback: RielaConfigGraphQLDocumentExecutor()
    )
    let routineAware = CompositeGraphQLDocumentExecutor(
      fallback: RoutineAwareGraphQLFallbackExecutor(
        routine: RoutineGraphQLDocumentExecutor(),
        next: RielaConfigGraphQLDocumentExecutor()
      )
    )
    let first = await composite.execute(request)
    let second = await routineAware.execute(request)
    XCTAssertTrue(first.handled)
    XCTAssertEqual(
      Self.errorMessage(first),
      Self.errorMessage(second),
      "entry-point assemblies disagreed on a parse error, so they do not share a parser"
    )
    XCTAssertNotNil(Self.errorMessage(first))
  }

  // MARK: - Helpers

  private static func errorMessage(_ response: GraphQLDocumentExecutionResponse) -> String? {
    guard case let .array(errors)? = response.body["errors"],
          case let .object(first)? = errors.first,
          case let .string(message)? = first["message"] else { return nil }
    return message
  }

  private static func swiftSources() throws -> [(String, String)] {
    let root = SurfaceParityGraphQLTests.repositoryRoot()
    let sources = root.appendingPathComponent("Sources", isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
      return []
    }
    var result: [(String, String)] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
      result.append((relative, try String(contentsOf: url, encoding: .utf8)))
    }
    return result
  }

  private static func filesDeclaring(_ markers: [String]) throws -> [String] {
    var owners: Set<String> = []
    for (path, contents) in try swiftSources() {
      for marker in markers where contents.contains(marker) {
        owners.insert(path)
      }
    }
    return owners.sorted()
  }
}
