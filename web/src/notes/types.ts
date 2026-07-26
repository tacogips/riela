export type NotebookProgress = 'none' | 'progress' | 'done' | 'pending'
export type NoteListSort = 'updatedAtDesc' | 'title' | 'createdAtDesc' | 'createdAtAsc'
export type HostMode = 'riela-app' | 'cli-serve'

export interface ControlResult {
  accepted: boolean
  status: string
  diagnostics: string[]
}

export interface NoteTag {
  tagId: string
  name: string
  classId: string | null
  parentTagId: string | null
  isSystem: boolean
  createdAt: string
}

export interface NoteTagClass {
  classId: string
  label: string
  description: string | null
}

export interface NoteTagAssignment {
  tag: NoteTag
  provenance: string
  assignedBy: string | null
  deletable: boolean
  createdAt: string
}

export interface Notebook {
  notebookId: string
  title: string
  progress: NotebookProgress
  createdAt: string
  updatedAt: string
  tags: NoteTagAssignment[]
  firstNotePreview?: string | null
  noteCount?: number | null
}

export interface Note {
  noteId: string
  notebookId: string
  noteNumber: number
  title: string | null
  bodyMarkdown: string
  readOnly: boolean
  createdAt: string
  updatedAt: string
}

export interface QueryPayload<T> {
  result: ControlResult
  value: T
}

export interface MutationPayload {
  result: ControlResult
  notebook?: Notebook | null
  tag?: NoteTag | null
}

export interface GraphQLEnvelope<T> {
  data?: T
  errors?: Array<{ message: string }>
  error?: string
}
