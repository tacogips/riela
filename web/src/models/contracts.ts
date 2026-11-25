import type { BotOrigin } from '../bots/contracts'

export interface CatalogModel {
  id: string
  label?: string | null
  sources: string[]
  reasoningEfforts: string[]
  serviceTiers: string[]
  modes: string[]
}

export interface ProviderInstance {
  instanceId: string
  driver: string
  label: string
  account?: string | null
  builtIn: boolean
  availability?: string | null
  authentication?: string | null
  version?: string | null
  probedAt?: string | null
  models: CatalogModel[]
  origin: BotOrigin
}

export interface SaveProviderInput {
  instanceId: string
  driver: string
  label?: string
  account?: string
  customModels: string[]
}
