import RielaCore

enum BuiltinNoteAddon: String, CaseIterable {
  case create = "kaiba/note-create", update = "kaiba/note-update"
  case get = "kaiba/note-get", search = "kaiba/note-search"
  case tagSearch = "kaiba/note-tag-search"
  case graphNeighbors = "kaiba/note-graph-neighbors"
  case chain = "kaiba/note-chain"
  case tagApply = "kaiba/note-tag-apply"
  case attachFile = "kaiba/note-attach-file"
  case attachments = "kaiba/note-attachments"
  case memos = "kaiba/note-memos"
  case graphQLDocument = "kaiba/note-graphql-document"
  case commentAdd = "kaiba/note-comment-add", notebookIngestPages = "kaiba/notebook-ingest-pages"
  case documentImport = "kaiba/document-import"
  case conversationSave = "kaiba/note-conversation-save"

  var outputName: String {
    rawValue.hasPrefix("kaiba/note-")
      ? String(rawValue.dropFirst("kaiba/note-".count))
      : String(rawValue.dropFirst("kaiba/".count))
  }
}

/// Long-term memory bridge: riela consolidates its short-term records into
/// kaiba's canonical memory notebook and recalls them back for prompts.
enum BuiltinKaibaLongTermMemoryAddon: String, CaseIterable {
  case consolidate = "kaiba/memory-consolidate"
  case recall = "kaiba/memory-recall"
}
