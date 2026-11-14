import Crypto
import Foundation
import RielaCore

/// Metadata safe for discovery. It deliberately contains no path, prompt,
/// contract, node payload, environment, or validation diagnostic.
public struct WorkflowCompactCatalogCard: Codable, Equatable, Sendable {
  public var workflowId: String
  public var workflowName: String
  public var shortSummary: String
  public var tags: [String]
  public var domain: String?
  public var originId: String
  public var sourceKind: WorkflowSourceKind
  public var scope: WorkflowScope
  public var provenance: WorkflowProvenance
  public var revision: String
  public var active: Bool

  public init(
    workflowId: String, workflowName: String, shortSummary: String, tags: [String], domain: String?,
    originId: String, sourceKind: WorkflowSourceKind, scope: WorkflowScope, provenance: WorkflowProvenance,
    revision: String, active: Bool
  ) {
    self.workflowId = workflowId; self.workflowName = workflowName; self.shortSummary = shortSummary
    self.tags = tags; self.domain = domain; self.originId = originId; self.sourceKind = sourceKind
    self.scope = scope; self.provenance = provenance; self.revision = revision; self.active = active
  }
}

/// Refresh uses the registry's authoritative scope, mutable-origin, and
/// activation logic. Listing reads a compact persisted index only; it does not
/// call bundle loading or put executable text into a discovery response.
public struct WorkflowCompactCatalog: Sendable {
  /// Production discovery has no callback. The package-visible seam keeps the
  /// mutation-during-capture boundary deterministic without timing assumptions.
  private let beforeCardRead: (@Sendable (WorkflowCatalogEntry) -> Void)?

  public init() {
    beforeCardRead = nil
  }

  init(beforeCardRead: @escaping @Sendable (WorkflowCatalogEntry) -> Void) {
    self.beforeCardRead = beforeCardRead
  }

  public func allCards(workingDirectory: String = FileManager.default.currentDirectoryPath) throws -> [WorkflowCompactCatalogCard] {
    try cachedRecords(workingDirectory).map(\.card)
  }

  @discardableResult
  public func refresh(workingDirectory: String = FileManager.default.currentDirectoryPath) throws -> [WorkflowCompactCatalogCard] {
    let records: [CompactRecord] = try WorkflowRegistryService().compactList(workingDirectory: workingDirectory).compactMap { entry -> CompactRecord? in
      // A broken package/header must not hide unrelated registered workflows.
      // Invalid bundles stay visible through the authoritative registry; they
      // never become executable specialist cards.
      beforeCardRead?(entry)
      guard let card = try? makeCard(entry) else { return nil }
      return CompactRecord(card: card, locator: entry.workflowDirectory)
    }.sorted { ($0.card.scope.rawValue, $0.card.originId, $0.card.workflowId) < ($1.card.scope.rawValue, $1.card.originId, $1.card.workflowId) }
    let url = indexURL(workingDirectory)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(CompactDocument(records: records)).write(to: url, options: .atomic)
    return records.map(\.card)
  }

  public func list(workingDirectory: String = FileManager.default.currentDirectoryPath, query: String? = nil, limit: Int = 100, cursor: String? = nil) throws -> [WorkflowCompactCatalogCard] {
    var cards = try cachedRecords(workingDirectory).map(\.card)
    let needle = normalized(query ?? "").lowercased()
    if !needle.isEmpty {
      cards = cards.filter { card in
        [card.workflowId, card.workflowName, card.shortSummary, card.domain ?? ""].joined(separator: " ").lowercased().contains(needle)
          || card.tags.joined(separator: " ").lowercased().contains(needle)
      }
    }
    cards.sort { ($0.scope.rawValue, $0.originId, $0.workflowId) < ($1.scope.rawValue, $1.originId, $1.workflowId) }
    if let cursor {
      guard let index = cards.firstIndex(where: { paginationCursor(for: $0) == cursor }) else {
        throw WorkflowRegistryError(code: .invalidOrigin, message: "catalog cursor is invalid or stale")
      }
      cards = Array(cards.dropFirst(index + 1))
    }
    return Array(cards.prefix(max(1, min(limit, 200))))
  }

  /// Opaque cursor for continuing a stable compact-card listing. Origin alone
  /// is insufficient because one origin can contain multiple workflow cards.
  public func paginationCursor(for card: WorkflowCompactCatalogCard) -> String {
    "\(card.scope.rawValue)|\(card.originId)|\(card.workflowId)"
  }

  private func cachedRecords(_ workingDirectory: String) throws -> [CompactRecord] {
    let url = indexURL(workingDirectory)
    if let data = try? Data(contentsOf: url), let document = try? JSONDecoder().decode(CompactDocument.self, from: data) {
      return document.records
    }
    _ = try refresh(workingDirectory: workingDirectory)
    return try JSONDecoder().decode(CompactDocument.self, from: Data(contentsOf: url)).records
  }

  /// Resolve across the complete index, then revalidate only the selected
  /// origin against the authoritative registry. Cached discovery never grants
  /// permission to execute a stale or inactive workflow.
  public func select(
    workflowId: String, originId: String? = nil,
    workingDirectory: String = FileManager.default.currentDirectoryPath
  ) throws -> WorkflowCompactCatalogCard {
    let candidates = try cachedRecords(workingDirectory).map(\.card).filter {
      $0.workflowId == workflowId && (originId == nil || $0.originId == originId)
    }
    guard !candidates.isEmpty else {
      throw WorkflowRegistryError(code: .invalidWorkflow, message: "workflow origin is ambiguous or unavailable")
    }
    let entry = try WorkflowRegistryService().fetch(
      target: WorkflowRegistryTarget(workflowId: workflowId, scope: .auto, originId: originId),
      workingDirectory: workingDirectory
    )
    let current = try makeCard(entry)
    guard let cached = candidates.first(where: { $0.originId == current.originId }),
          current.active, current.revision == cached.revision else {
      throw WorkflowRegistryError(code: .invalidWorkflow, message: "selected workflow is inactive or changed; refresh the catalog")
    }
    return current
  }

  private func makeCard(_ entry: WorkflowCatalogEntry) throws -> WorkflowCompactCatalogCard {
    let directory = URL(fileURLWithPath: entry.workflowDirectory, isDirectory: true)
    let definitionURL = directory.appendingPathComponent("workflow.json")
    let object: [String: Any]?
    let data = try Data(contentsOf: definitionURL)
    let decoded = try JSONSerialization.jsonObject(with: data)
    object = decoded as? [String: Any]
    let id = (object?["workflowId"] as? String) ?? entry.workflowId
    let summary = bounded(
      (object?["shortSummary"] as? String) ?? (object?["description"] as? String) ?? entry.description ?? "Workflow \(id)",
      max: 240
    )
    let tags = Array(((object?["tags"] as? [String]) ?? []).prefix(8)).map { bounded($0, max: 32) }.filter { !$0.isEmpty }
    let domain = (object?["domain"] as? String).map { bounded($0, max: 64) }.flatMap { $0.isEmpty ? nil : $0 }
    return WorkflowCompactCatalogCard(
      workflowId: id, workflowName: entry.workflowName, shortSummary: summary, tags: tags, domain: domain,
      originId: entry.originId, sourceKind: entry.sourceKind, scope: entry.scope, provenance: entry.provenance,
      revision: try closureRevision(workflowDirectory: directory), active: entry.valid && entry.activationState == .active
    )
  }

  private func indexURL(_ workingDirectory: String) -> URL { URL(fileURLWithPath: workingDirectory, isDirectory: true).appendingPathComponent(".riela/specialist-catalog.json") }

  /// Hashes opaque assets without decoding them, so execution drift invalidates
  /// a card even where mtime and size are unchanged.
  /// Computes the executable-closure digest used by both the registry card and
  /// the runtime-owned capture.  The caller must not execute a directory until
  /// this value has been compared with the sealed dispatch revision.
  public func closureRevision(workflowDirectory directory: URL) throws -> String {
    let rootValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
      throw WorkflowRegistryError(code: .invalidWorkflow, message: "workflow capture root must be a real directory")
    }
    guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
      throw WorkflowRegistryError(code: .invalidWorkflow, message: "workflow assets cannot be enumerated")
    }
    var assets: [URL] = []
    for case let file as URL in files {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true else { throw WorkflowRegistryError(code: .invalidWorkflow, message: "workflow contains a symbolic link") }
      guard values.isRegularFile == true else { continue }
      assets.append(file)
      guard assets.count <= 512 else { throw WorkflowRegistryError(code: .invalidWorkflow, message: "workflow has too many executable assets") }
    }
    var hasher = SHA256()
    for file in assets.sorted(by: { $0.path < $1.path }) {
      let relative = String(file.path.dropFirst(directory.path.count + 1))
      hasher.update(data: Data(relative.utf8)); hasher.update(data: Data([0]))
      hasher.update(data: Data(SHA256.hash(data: try Data(contentsOf: file)))); hasher.update(data: Data([0]))
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
      hasher.update(data: Data([mode & 0o111 != 0 ? 1 : 0]))
    }
    return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func normalized(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
  private func bounded(_ value: String, max: Int) -> String { String(normalized(value).unicodeScalars.prefix(max)) }
}

private struct CompactDocument: Codable { let records: [CompactRecord] }
private struct CompactRecord: Codable { let card: WorkflowCompactCatalogCard; let locator: String }
