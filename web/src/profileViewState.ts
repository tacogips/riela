export type NavigationView = 'instances' | 'logs' | 'workflows' | 'ops' | 'settings'
export type View = NavigationView | 'workflow-detail' | 'run-detail' | 'ops-run'

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
  const fallbackView = currentView === 'workflow-detail' ? 'workflows' : currentView === 'run-detail' ? 'workflows' : currentView === 'ops-run' ? 'ops' : currentView
  return {
    clearSelection: profileChanged,
    view: profileChanged ? fallbackView : currentView,
  }
}

