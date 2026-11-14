import { APIError, api } from '../../api'
import { rielaFetch } from '../../transport'
import type { ConsoleClientEnvironment } from '../../console/client'

export interface Audit { auditId: string; operation: string; versionId: string; previousVersionId: string | null; reason: string; evidence: string[]; actor: { kind: string; id: string }; createdAt: string; retained: boolean }
export interface Diff { path: string; op: string; before: string | null; after: string | null }
export interface Proposal { proposalId: string; regressedVersionId: string; rollbackToVersionId: string; baselineSessionId: string; targetSessionId: string; policy: string; regressions: { kind: string; gateId: string | null; detail: string }[] }
type Result<T> = { data?: T; errors?: { message: string; extensions?: { code?: string } }[] }

export class WorkflowHistoryClient {
  constructor(private readonly environment: ConsoleClientEnvironment) {}
  private async execute<T>(query: string, variables: Record<string, unknown>, operationName: string): Promise<T> {
    const response = await this.environment.request('/graphql', { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json', ...this.environment.appHeaders() }, body: JSON.stringify({ query, variables, operationName }) })
    let payload: Result<T>
    try { payload = JSON.parse(await response.text()) as Result<T> } catch { throw new APIError('The console returned invalid JSON.', response.status, 'invalid_response') }
    const error = payload.errors?.[0]
    if (!response.ok || error || !payload.data) throw new APIError(error?.message ?? `Console request failed (${response.status})`, response.status, error?.extensions?.code ?? 'console_request_failed')
    return payload.data
  }
  async history(workflowName: string) {
    const data = await this.execute<{ workflowDefinitionHistory: Audit[] }>(`query WorkflowHistory($workflowName: String!) { workflowDefinitionHistory(workflowName: $workflowName, limit: 50) { auditId operation versionId previousVersionId reason evidence actor { kind id } createdAt retained } }`, { workflowName }, 'WorkflowHistory')
    return data.workflowDefinitionHistory
  }
  async head(workflowName: string) {
    const data = await this.execute<{ workflowDefinition: { versionId: string; revision: number | null } | null }>(`query WorkflowHead($workflowName: String!) { workflowDefinition(workflowName: $workflowName) { versionId revision } }`, { workflowName }, 'WorkflowHead')
    return data.workflowDefinition
  }
  async diff(workflowName: string, fromVersionId: string, toVersionId: string) {
    const data = await this.execute<{ workflowDefinitionDiff: Diff[] }>(`query WorkflowDiff($workflowName: String!, $fromVersionId: String, $toVersionId: String) { workflowDefinitionDiff(workflowName: $workflowName, fromVersionId: $fromVersionId, toVersionId: $toVersionId) { path op before after } }`, { workflowName, fromVersionId, toVersionId }, 'WorkflowDiff')
    return data.workflowDefinitionDiff
  }
  async restore(workflowName: string, versionId: string, reason: string, expectedVersionId: string) {
    return this.execute(`mutation RestoreDefinition($input: RestoreWorkflowDefinitionInput!) { restoreWorkflowDefinition(input: $input) { version { versionId } audit { auditId } } }`, { input: { workflowName, versionId, reason, expectedVersionId } }, 'RestoreDefinition')
  }
  async undo(workflowName: string, reason: string, expectedVersionId: string) {
    return this.execute(`mutation UndoDefinition($input: UndoWorkflowDefinitionInput!) { undoWorkflowDefinition(input: $input) { version { versionId } audit { auditId } } }`, { input: { workflowName, reason, expectedVersionId } }, 'UndoDefinition')
  }
  async proposals(workflowName: string) {
    const data = await this.execute<{ workflowRollbackProposals: Proposal[] }>(`query RollbackProposals($workflowName: String!) { workflowRollbackProposals(workflowName: $workflowName, status: "pending") { proposalId regressedVersionId rollbackToVersionId baselineSessionId targetSessionId policy regressions { kind gateId detail } } }`, { workflowName }, 'RollbackProposals')
    return data.workflowRollbackProposals
  }
  async approve(workflowName: string, proposalId: string, reason: string) {
    return this.execute(`mutation ApproveRollback($input: ApproveWorkflowRollbackProposalInput!) { approveWorkflowRollbackProposal(input: $input) { proposalId } }`, { input: { workflowName, proposalId, reason: reason || null } }, 'ApproveRollback')
  }
  async reject(workflowName: string, proposalId: string, reason: string) {
    return this.execute(`mutation RejectRollback($input: RejectWorkflowRollbackProposalInput!) { rejectWorkflowRollbackProposal(input: $input) { proposalId } }`, { input: { workflowName, proposalId, reason } }, 'RejectRollback')
  }
}
export const historyClient = new WorkflowHistoryClient({ request: (input, init) => rielaFetch(input, init), appHeaders: () => api.noteHeaders() })
