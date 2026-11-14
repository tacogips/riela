import type { RunDetailLog, RunDetailStep } from '../contracts'

export function logsForStepExecution(
  logs: RunDetailLog[],
  step: RunDetailStep,
): RunDetailLog[] {
  return logs.filter((log) => log.sourceStepExecutionId === step.executionId)
}

export function routingLogsWithoutVisibleExecution(
  logs: RunDetailLog[],
  steps: RunDetailStep[],
): RunDetailLog[] {
  const visibleExecutionIds = new Set(steps.map((step) => step.executionId))
  return logs.filter((log) =>
    !log.sourceStepExecutionId || !visibleExecutionIds.has(log.sourceStepExecutionId))
}
