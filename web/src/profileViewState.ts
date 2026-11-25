export type NavigationView = 'instances' | 'logs' | 'workflows' | 'ops' | 'bots' | 'models' | 'settings'
export type View = NavigationView | 'workflow-detail' | 'run-detail' | 'ops-run' | 'bot-detail'

export interface ProfileViewTransition {
  clearSelection: boolean
  view: View
}

export function profileViewTransition(
  previousProfileKey: string | undefined,
  nextProfileKey: string,
  mode: 'riela-app' | 'cli-serve' | undefined,
  currentView: View,
): ProfileViewTransition {
  const profileChanged = previousProfileKey !== undefined && previousProfileKey !== nextProfileKey
  void mode
  let fallbackView = currentView
  if (currentView === 'workflow-detail' || currentView === 'run-detail') fallbackView = 'workflows'
  if (currentView === 'ops-run') fallbackView = 'ops'
  if (currentView === 'bot-detail') fallbackView = 'bots'
  return {
    clearSelection: profileChanged,
    view: profileChanged ? fallbackView : currentView,
  }
}


export interface AskViewState {
  open: boolean
  active?: { conversationId: string; remote: string }
}

export function readAskViewState(key: string): AskViewState {
  try {
    const value = JSON.parse(sessionStorage.getItem(`riela.ask.${key}`) ?? 'null') as AskViewState | null
    const active = value?.active
    return { open: value?.open === true, active: typeof active?.conversationId === 'string' &&
      typeof active.remote === 'string' ? active : undefined }
  } catch {
    return { open: false }
  }
}

export function writeAskViewState(key: string, state: AskViewState) {
  try { sessionStorage.setItem(`riela.ask.${key}`, JSON.stringify(state)) } catch { /* Storage is optional. */ }
}
