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

