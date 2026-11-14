export type JSONValue = string | number | boolean | null | JSONValue[] | { [key: string]: JSONValue }

export interface Bootstrap {
  apiVersion: 'v1'
  profile: string
  csrfToken: string
  revision: number
  capabilities: string[]
  server: WebServerSettings
}

export interface Instance {
  id: string
  name: string
  workflowId: string
  source: string
  status: string
  statusDetail: string
  active: boolean
  enabledAtLaunch: boolean
  workingDirectory: string | null
  environmentFilePath: string | null
  environmentVariables: Record<string, string>
  workflowVariables: Record<string, JSONValue>
  nodePatchCount: number
  eventSources: Array<{ id: string; kind: string }>
}

export interface InstancesResponse {
  revision: number
  items: Instance[]
}

export interface InstanceResponse {
  revision: number
  item: Instance
}

export interface WorkflowSources {
  revision: number
  directories: string[]
  projectDirectories: string[]
  repositories: Array<{ id: string; source: string }>
  discovered: Array<{ id: string; name: string; workflowId: string; scope: string }>
}

export interface AssistantSettings {
  revision: number
  assistance: string
  vendor: string
  model: string
}

export interface NoteSettings {
  revision: number
  exposesNoteAPI: boolean
  defaultTranslationTargetLanguage: string
  s3ProfileCount: number
}

export interface WebServerSettings {
  revision: number
  isEnabled: boolean
  configuredPort: number
  boundPort: number | null
  restartRequired: boolean
  state: string
}

export interface ExecutionsResponse {
  revision: number
  instanceId: string
  items: Array<Record<string, JSONValue>>
  diagnostic?: string
}

export interface APIErrorPayload {
  error: { code: string; message: string }
  revision: number
}
