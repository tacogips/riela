import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

/// Skill surface gate (CSP-2/CSP-7). Skills are read by agents as fact, so a
/// command or flag a skill documents must exist. The scanner is Swift and runs
/// inside `swift test` (delta D4); `Resources/skills` is the canonical in-repo
/// skill set (delta D1).
final class SurfaceParitySkillTests: XCTestCase {
  /// Prose tokens that look like flags but are not riela options.
  static let allowedProseTokens: Set<String> = []

  /// Skills that must not be carried into the canonical set. "Deleted" means
  /// exactly this for `riela-auto-improve` (delta D1).
  static let rejectedSkillNames: Set<String> = ["riela-auto-improve"]

  func testCanonicalSkillSetIsPresentAndRejectedSkillsAreAbsent() throws {
    let names = try Self.skillNames()
    XCTAssertEqual(names, ["riela-workflow-reference", "riela-workflow-run"])
    for rejected in Self.rejectedSkillNames {
      XCTAssertFalse(names.contains(rejected), "\(rejected) must not be part of the canonical skill set")
    }
  }

  func testEveryDocumentedCommandResolvesToACatalogRow() throws {
    var violations: [SurfaceParityViolation] = []
    for document in try Self.skillDocuments() {
      for command in Self.documentedCommands(in: document.contents) where !Self.resolves(command: command) {
        violations.append(.init(
          surface: .skill,
          subject: "\(document.path): riela \(command)",
          reason: "no catalog row declares this command"
        ))
      }
    }
    XCTAssertTrue(
      violations.isEmpty,
      "skill command violations:\n" + violations.map(\.description).joined(separator: "\n")
    )
  }

  func testEveryDocumentedFlagIsAnOptionSomeParserAccepts() throws {
    let known = CLISurfaceEnumerator.optionNames().union(Self.allowedProseTokens)
    var violations: [String] = []
    for document in try Self.skillDocuments() {
      for token in Self.documentedFlags(in: document.contents) where !known.contains(token) {
        violations.append("\(document.path): \(token)")
      }
    }
    XCTAssertTrue(violations.isEmpty, "skills document flags no parser accepts:\n" + violations.joined(separator: "\n"))
  }

  /// The gate that would have caught `--supervisor-workflow`.
  func testAStaleFlagIsRejected() {
    let known = CLISurfaceEnumerator.optionNames().union(Self.allowedProseTokens)
    for stale in ["--supervisor-workflow", "--no-allow-targeted-rerun"] {
      XCTAssertFalse(known.contains(stale), "\(stale) does not exist and must be rejected")
      XCTAssertEqual(
        Self.documentedFlags(in: "Run `riela workflow run x \(stale)` to supervise."),
        [stale],
        "the scanner must see the stale token"
      )
    }
  }

  func testAnUnknownCommandIsRejected() {
    XCTAssertFalse(Self.resolves(command: "supervisor start"))
    XCTAssertTrue(Self.resolves(command: "workflow run my-workflow --variables {}"))
  }

  /// Design 2.5: each skill's command block is generated from the catalog's
  /// CLI bindings for the family it names, so a renamed command fails here.
  func testGeneratedCommandBlocksMatchTheCatalog() throws {
    for document in try Self.skillDocuments() {
      for block in Self.catalogBlocks(in: document.contents) {
        let expected = SurfaceCatalog.operations(inFamily: block.family)
          .filter { $0.isImplemented(on: .cli) }
          .compactMap { $0.cli?.command }
          .map { "riela \($0)" }
        XCTAssertEqual(
          block.lines,
          expected,
          "\(document.path): the '\(block.family)' command block is not the catalog's block"
        )
      }
    }
  }

  func testEverySkillDocumentsAtLeastOneGeneratedBlock() throws {
    for document in try Self.skillDocuments() {
      XCTAssertFalse(
        Self.catalogBlocks(in: document.contents).isEmpty,
        "\(document.path) has no generated command block"
      )
    }
  }

  // MARK: - Scanning

  struct SkillDocument {
    var path: String
    var contents: String
  }

  struct CatalogBlock {
    var family: String
    var lines: [String]
  }

  static func skillsRoot() -> URL {
    SurfaceParityLibraryTests.repositoryRoot().appendingPathComponent("Resources/skills", isDirectory: true)
  }

  static func skillNames() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: skillsRoot().path)
      .filter { !$0.hasPrefix(".") }
      .sorted()
  }

  static func skillDocuments() throws -> [SkillDocument] {
    let root = skillsRoot()
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
      return []
    }
    var documents: [SkillDocument] = []
    for case let url as URL in enumerator where url.pathExtension == "md" {
      documents.append(SkillDocument(
        path: url.path.replacingOccurrences(of: root.deletingLastPathComponent().path + "/", with: ""),
        contents: try String(contentsOf: url, encoding: .utf8)
      ))
    }
    XCTAssertFalse(documents.isEmpty, "no skill documents were found under Resources/skills")
    return documents.sorted { $0.path < $1.path }
  }

  /// Every `riela …` invocation a skill documents, with the leading `riela`
  /// removed. Both fenced blocks and inline code are scanned.
  static func documentedCommands(in contents: String) -> [String] {
    var commands: [String] = []
    var remainder = Substring(contents)
    while let start = remainder.range(of: "riela ") {
      let rest = remainder[start.upperBound...]
      let line = rest.prefix { $0 != "\n" && $0 != "`" }
      let trimmed = line
        .trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
      if !trimmed.isEmpty, trimmed.first?.isLetter == true {
        commands.append(trimmed)
      }
      remainder = remainder[start.upperBound...]
    }
    return commands
  }

  static func documentedFlags(in contents: String) -> [String] {
    CLISurfaceEnumerator.longOptionTokens(in: contents).sorted()
  }

  /// A documented line resolves when its leading tokens are a catalog command.
  static func resolves(command: String) -> Bool {
    let tokens = command.split(separator: " ").map(String.init)
    let declared = SurfaceCatalog.declaredCLICommands
    return stride(from: min(tokens.count, 3), through: 1, by: -1).contains { length in
      declared.contains(tokens.prefix(length).joined(separator: " "))
    }
  }

  static func catalogBlocks(in contents: String) -> [CatalogBlock] {
    var blocks: [CatalogBlock] = []
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var index = 0
    while index < lines.count {
      let line = lines[index].trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix("<!-- surface-catalog:begin "), line.hasSuffix(" -->") else {
        index += 1
        continue
      }
      let family = line
        .dropFirst("<!-- surface-catalog:begin ".count)
        .dropLast(" -->".count)
        .trimmingCharacters(in: .whitespaces)
      var commands: [String] = []
      index += 1
      while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("<!-- surface-catalog:end") {
        let entry = lines[index].trimmingCharacters(in: .whitespaces)
        if entry.hasPrefix("riela ") {
          commands.append(entry)
        }
        index += 1
      }
      blocks.append(CatalogBlock(family: family, lines: commands))
      index += 1
    }
    return blocks
  }
}
