import RielaCore

enum BuiltinNoteAddon: String {
  case create = "kaiba/note-create", update = "kaiba/note-update"
  case get = "kaiba/note-get", search = "kaiba/note-search"
  case graphNeighbors = "kaiba/note-graph-neighbors"
  case tagApply = "kaiba/note-tag-apply"
  case attachFile = "kaiba/note-attach-file"
  case graphQLDocument = "kaiba/note-graphql-document"
  case commentAdd = "kaiba/note-comment-add", notebookIngestPages = "kaiba/notebook-ingest-pages"
  case conversationSave = "kaiba/note-conversation-save"
  case kanbanTaskCreate = "kaiba/note-kanban-task-create"
  case kanbanMove = "kaiba/note-kanban-move", kanbanBoard = "kaiba/note-kanban-board"
}

/// Long-term memory bridge: riela consolidates its short-term records into
/// kaiba's canonical memory notebook and recalls them back for prompts.
enum BuiltinKaibaLongTermMemoryAddon: String {
  case consolidate = "kaiba/memory-consolidate"
  case recall = "kaiba/memory-recall"
}
