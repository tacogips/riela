import type { AskAction } from './contracts'

function actionTitle(action: AskAction): string {
  switch (action.kind) {
    case 'stopSession': return `Stop run ${action.target.sessionId}`
    case 'rerunSession': return `Rerun ${action.target.sessionId}`
    case 'answerBotRequest': return action.target.decline
      ? `Decline request ${action.target.requestId}`
      : `Answer request ${action.target.requestId} (${action.target.optionId ?? ''})`
    case 'setBotPaused': return `${action.target.paused ? 'Pause' : 'Resume'} bot ${action.target.botId}`
    case 'applyWorkflow': return `Apply workflow ${action.target.workflowId}`
  }
}

export function actionCard(action: AskAction, now = Date.now()) {
  const expired = !(Date.parse(action.expiresAt) > now)
  return {
    title: actionTitle(action),
    detail: action.reason,
    state: action.result?.code ?? action.result?.summary ?? (action.status === 'proposed' && expired ? 'expired' : action.status),
    canDecide: action.status === 'proposed' && !expired,
  }
}
