import Foundation
import RielaNote

public extension RielaNoteLibraryViewModel {
  func isExpandingNotebook(_ notebookId: String) -> Bool {
    expandingNotebookIds.contains(notebookId)
  }

  func expandNotebook(_ notebook: Notebook) async {
    let notebookId = notebook.notebookId
    if let existingTask = notebookExpansionTasks[notebookId] {
      _ = try? await existingTask.value
      return
    }
    notebookExpansionError = nil
    expandingNotebookIds.insert(notebookId)
    let task = Task { @MainActor [client] in
      try await buildNotebookExpansion(notebook: notebook, client: client)
    }
    notebookExpansionTasks[notebookId] = task
    defer {
      notebookExpansionTasks[notebookId] = nil
      expandingNotebookIds.remove(notebookId)
    }
    do {
      notebookExpansionSession = try await task.value
    } catch {
      rielaNoteLogUIError("notebookExpansion.expand", error)
      notebookExpansionError = notebookExpansionFailureMessage(error)
    }
  }
}

@MainActor
private func buildNotebookExpansion(
  notebook: Notebook,
  client: any RielaNoteUIClient
) async throws -> RielaNoteNotebookExpansionSession {
  guard client.isNotebookExpansionConfigured else {
    throw RielaNoteNotebookExpansionError.notConfigured
  }
  let currentNotebook = try await client.notebookForExpansion(notebookId: notebook.notebookId)
  let currentMarker = notebookExpansionMarker(for: currentNotebook)
  if let cache = notebookCompactCache(from: currentNotebook.metaJSON),
     notebookCompactCacheIsValid(cache, marker: currentMarker) {
    return try await saveNotebookExpansion(
      sourceNotebook: currentNotebook,
      marker: currentMarker,
      cache: cache,
      client: client
    )
  }

  for attempt in 0...1 {
    let sourceNotebook = try await client.notebookForExpansion(notebookId: notebook.notebookId)
    let sourceMarker = notebookExpansionMarker(for: sourceNotebook)
    let notes = try await client.notesForNotebookExpansion(notebookId: notebook.notebookId)
      .sorted { lhs, rhs in
        lhs.noteNumber == rhs.noteNumber ? lhs.noteId < rhs.noteId : lhs.noteNumber < rhs.noteNumber
      }
    guard notes.count == sourceMarker.noteCount else {
      if attempt == 0 {
        continue
      }
      throw RielaNoteNotebookExpansionError.sourceChanged
    }
    let draft = try await client.compactNotebook(request: RielaNoteNotebookCompactRequest(
      notebookId: sourceNotebook.notebookId,
      notebookTitle: sourceNotebook.title,
      sourceNotes: notes.map { note in
        RielaNoteNotebookCompactSourceNote(
          noteId: note.noteId,
          noteNumber: note.noteNumber,
          bodyMarkdown: note.bodyMarkdown
        )
      }
    ))
    let summary = draft.summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
    guard draft.version == RielaNoteNotebookCompactCache.supportedVersion, !summary.isEmpty else {
      throw RielaNoteNotebookExpansionError.invalidOutput
    }
    let verifiedNotebook = try await client.notebookForExpansion(notebookId: notebook.notebookId)
    guard notebookExpansionMarker(for: verifiedNotebook) == sourceMarker else {
      if attempt == 0 {
        continue
      }
      throw RielaNoteNotebookExpansionError.sourceChanged
    }
    let cache = RielaNoteNotebookCompactCache(
      version: draft.version,
      summaryMarkdown: summary,
      computedAt: notebookExpansionTimestamp(),
      sourceNoteIds: notes.map(\.noteId),
      source: sourceMarker
    )
    let cacheJSON = try encodedJSONString(cache)
    _ = try await client.updateNotebookCompactCache(
      notebookId: notebook.notebookId,
      compactMetadataJSON: cacheJSON
    )
    return try await saveNotebookExpansion(
      sourceNotebook: sourceNotebook,
      marker: sourceMarker,
      cache: cache,
      client: client
    )
  }
  throw RielaNoteNotebookExpansionError.sourceChanged
}

@MainActor
private func saveNotebookExpansion(
  sourceNotebook: Notebook,
  marker: RielaNoteNotebookExpansionSourceMarker,
  cache: RielaNoteNotebookCompactCache,
  client: any RielaNoteUIClient
) async throws -> RielaNoteNotebookExpansionSession {
  let metadata = RielaNoteNotebookExpansionMetadata(
    version: RielaNoteNotebookCompactCache.supportedVersion,
    sourceNotebookId: sourceNotebook.notebookId,
    sourceNoteIds: cache.sourceNoteIds,
    source: marker,
    compactSummaryMarkdown: cache.summaryMarkdown
  )
  let metadataJSON = try notebookExpansionMetadataJSONString(metadata)
  let saved = try await client.saveNotebookExpansion(
    title: "\(sourceNotebook.title) - Agent Expansion",
    seedPromptMarkdown: "Expand this notebook into useful key points and follow-up directions.",
    compactSummaryMarkdown: cache.summaryMarkdown,
    notebookMetaJSON: metadataJSON,
    sourceNoteIds: cache.sourceNoteIds
  )
  guard let initialNoteId = saved.notes.first?.noteId else {
    throw RielaNoteNotebookExpansionError.invalidOutput
  }
  return RielaNoteNotebookExpansionSession(
    sourceNotebookId: sourceNotebook.notebookId,
    conversationNotebookId: saved.notebook.notebookId,
    initialNoteId: initialNoteId,
    compactSummaryMarkdown: cache.summaryMarkdown,
    sourceNoteIds: cache.sourceNoteIds,
    sourceMarker: marker
  )
}

func notebookExpansionMarker(for notebook: Notebook) -> RielaNoteNotebookExpansionSourceMarker {
  RielaNoteNotebookExpansionSourceMarker(
    updatedAt: notebook.updatedAt,
    noteCount: notebook.noteCount ?? 0
  )
}

func notebookCompactCache(from metaJSON: String?) -> RielaNoteNotebookCompactCache? {
  guard let metaJSON,
        let data = metaJSON.data(using: .utf8),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let rielaNote = root["rielaNote"] as? [String: Any],
        let compact = rielaNote["notebookCompact"],
        JSONSerialization.isValidJSONObject(compact),
        let compactData = try? JSONSerialization.data(withJSONObject: compact) else {
    return nil
  }
  return try? JSONDecoder().decode(RielaNoteNotebookCompactCache.self, from: compactData)
}

func notebookCompactCacheIsValid(
  _ cache: RielaNoteNotebookCompactCache,
  marker: RielaNoteNotebookExpansionSourceMarker
) -> Bool {
  cache.version == RielaNoteNotebookCompactCache.supportedVersion
    && !cache.summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    && cache.source == marker
    && cache.sourceNoteIds.count == marker.noteCount
}

private func notebookExpansionMetadataJSONString(
  _ metadata: RielaNoteNotebookExpansionMetadata
) throws -> String {
  let data = try JSONEncoder().encode(metadata)
  let object = try JSONSerialization.jsonObject(with: data)
  let root = ["rielaNote": ["notebookExpansion": object]]
  let rootData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  guard let json = String(data: rootData, encoding: .utf8) else {
    throw RielaNoteNotebookExpansionError.invalidOutput
  }
  return json
}

private func encodedJSONString<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let data = try encoder.encode(value)
  guard let json = String(data: data, encoding: .utf8) else {
    throw RielaNoteNotebookExpansionError.invalidOutput
  }
  return json
}

private func notebookExpansionTimestamp() -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: Date())
}

private func notebookExpansionFailureMessage(_ error: Error) -> String {
  switch error {
  case RielaNoteNotebookExpansionError.notConfigured:
    "Notebook expansion is not configured."
  case RielaNoteNotebookExpansionError.sourceChanged:
    "The notebook changed while it was being summarized. Try again."
  case RielaNoteNotebookExpansionError.timedOut:
    "Notebook expansion timed out."
  default:
    "Couldn't expand this notebook. Please try again."
  }
}
