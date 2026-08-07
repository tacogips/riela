import RielaCore

let legacyPersonaMemoryConfigKeys = [
  "memoryId",
  "memoryDatabaseId",
  "memoryDatabase",
  "memoryPath",
  "storagePath"
]

let noteMemorySaveConfigKeys: Set<String> = [
  "streamId", "memoryId", "nodeId", "memoryNodeId", "payloadTemplate", "payload", "payloadSource",
  "tags", "attachments", "files", "imagePaths", "noteRoot", "maxAttachmentBytes", "localFileRoot",
  "workingDirectory", "allowLocalFileReferencesOutsideWorkingDirectory"
]

let noteMemoryLoadConfigKeys: Set<String> = [
  "streamId", "memoryId", "limit", "workflowScopeOnly", "nodeScope", "noteRoot"
]

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
  case memorySave = "kaiba/note-memory-save", memoryLoad = "kaiba/note-memory-load"
  case personaContextRead = "kaiba/note-persona-context-read", personaContextWrite = "kaiba/note-persona-context-write"
}
