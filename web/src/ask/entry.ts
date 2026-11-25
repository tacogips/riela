import { createSignal } from 'solid-js'
import type { GraphDocument } from '../workflows/graph'
import type { AskContextDisplay } from './context'

export interface AskEditor {
  key: string
  workflowId: () => string
  draft: () => GraphDocument
  canApply: () => boolean
  apply: (definition: GraphDocument) => void
}

export const [askEntry, openAsk] = createSignal<AskContextDisplay | undefined>(undefined, { equals: false })
export const [askEditor, setAskEditor] = createSignal<AskEditor>()

export function closeAskEditor(editor: AskEditor) {
  if (askEditor() === editor) setAskEditor(undefined)
}
