import RielaCore

enum NoteCommandGraphQLDocuments {
  static let controlResult = "accepted status diagnostics"

  static let tag = "tagId name classId isSystem createdAt"

  static let tagAssignment = """
  provenance assignedBy deletable createdAt
  tag { \(tag) }
  """

  static let note = """
  noteId notebookId noteNumber title bodyMarkdown readOnly createdAt updatedAt metaJSON
  tags { \(tagAssignment) }
  """

  static let notebook = """
  notebookId title progress createdAt updatedAt metaJSON firstNotePreview noteCount
  tags { \(tagAssignment) }
  """

  static let file = """
  fileId storageKind localPath s3Profile s3Bucket s3Key mediaType byteSize sha256 originalFilename createdAt migratedAt
  """

  static let comment = "commentId noteId bodyMarkdown author createdAt"

  static let link = "fromNoteId toNoteId linkKind provenance createdAt"

  static let autoAction = "actionId trigger workflowId filterJSON enabled position createdAt"

  static let mutationNotes = "notes { \(note) }"

  static let createNote = """
  mutation CreateNote($input: CreateNoteInput!) {
    createNote(input: $input) {
      result { \(controlResult) }
      \(mutationNotes)
      note { \(note) }
    }
  }
  """

  static let updateNote = """
  mutation UpdateNote($input: UpdateNoteInput!) {
    updateNote(input: $input) {
      result { \(controlResult) }
      \(mutationNotes)
      note { \(note) }
    }
  }
  """

  static let applyNoteTags = """
  mutation ApplyNoteTags($input: ApplyNoteTagsInput!) {
    applyNoteTags(input: $input) {
      result { \(controlResult) }
      \(mutationNotes)
      note { \(note) }
    }
  }
  """

  static let addNoteComment = """
  mutation AddNoteComment($input: AddNoteCommentInput!) {
    addNoteComment(input: $input) {
      result { \(controlResult) }
      \(mutationNotes)
      comment { \(comment) }
    }
  }
  """

  static let setNoteReadOnly = """
  mutation SetNoteReadOnly($noteId: String!, $readOnly: Boolean!) {
    setNoteReadOnly(noteId: $noteId, readOnly: $readOnly) {
      result { \(controlResult) }
      \(mutationNotes)
      note { \(note) }
    }
  }
  """

  static let createNotebook = """
  mutation CreateNotebook($input: CreateNotebookInput!) {
    createNotebook(input: $input) {
      result { \(controlResult) }
      \(mutationNotes)
      notebook { \(notebook) }
    }
  }
  """

  static let migrateAllNoteFiles = """
  mutation MigrateAllNoteFiles($input: MigrateAllNoteFilesInput!) {
    migrateAllNoteFiles(input: $input) {
      result { \(controlResult) }
      migrated { \(file) }
      failures { fileId message }
      cleanupFailures { fileId message }
    }
  }
  """

  static let reclaimNoteFileStorage = """
  mutation ReclaimNoteFileStorage($input: ReclaimNoteFileStorageInput!) {
    reclaimNoteFileStorage(input: $input) {
      result { \(controlResult) }
      deletedFileIds
      sweptPaths
    }
  }
  """

  static let notes = """
  query Notes($limit: Int, $offset: Int, $notebookId: String, $tagFilter: [String!]) {
    notes(limit: $limit, offset: $offset, notebookId: $notebookId, tagFilter: $tagFilter) {
      value { \(note) }
      result { \(controlResult) }
    }
  }
  """

  static let searchNotes = """
  query SearchNotes($query: String!, $tagFilter: [String!], $classFilter: [String!], $limit: Int, $offset: Int) {
    searchNotes(query: $query, tagFilter: $tagFilter, classFilter: $classFilter, limit: $limit, offset: $offset) {
      value {
        note { \(note) }
        snippet
        rank
        matchedTags { \(tag) }
        isLinkedNeighbor
      }
      result { \(controlResult) }
    }
  }
  """

  static let removeNoteTag = """
  mutation RemoveNoteTag($noteId: String!, $tagName: String!, $provenance: String) {
    removeNoteTag(noteId: $noteId, tagName: $tagName, provenance: $provenance) {
      result { \(controlResult) }
      \(mutationNotes)
      note { \(note) }
    }
  }
  """

  static let migrateNoteFileStorage = """
  mutation MigrateNoteFileStorage($input: MigrateNoteFileStorageInput!) {
    migrateNoteFileStorage(input: $input) {
      result { \(controlResult) }
      migrated { \(file) }
      failures { fileId message }
    }
  }
  """
}

func boolOption(_ token: String, _ raw: String) throws -> Bool {
  switch raw.lowercased() {
  case "true", "yes", "1", "on":
    return true
  case "false", "no", "0", "off":
    return false
  default:
    throw CLIUsageError("\(token) requires a boolean value")
  }
}
