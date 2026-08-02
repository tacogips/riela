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
  case create = "riela/note-create", update = "riela/note-update"
  case get = "riela/note-get", search = "riela/note-search"
  case graphNeighbors = "riela/note-graph-neighbors"
  case tagApply = "riela/note-tag-apply"
  case attachFile = "riela/note-attach-file"
  case graphQLDocument = "riela/note-graphql-document"
  case commentAdd = "riela/note-comment-add", notebookIngestPages = "riela/notebook-ingest-pages"
  case conversationSave = "riela/note-conversation-save"
  case kanbanTaskCreate = "riela/note-kanban-task-create"
  case kanbanMove = "riela/note-kanban-move", kanbanBoard = "riela/note-kanban-board"
  case memorySave = "riela/note-memory-save", memoryLoad = "riela/note-memory-load"
  case personaContextRead = "riela/note-persona-context-read", personaContextWrite = "riela/note-persona-context-write"
}
