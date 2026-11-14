#if os(macOS)
import Foundation
import RielaAppSupport

extension RielaApp {
  private var marketplaceCatalogLoader: RielaAppWorkflowRepositoryCatalogLoader {
    RielaAppWorkflowRepositoryCatalogLoader(
      cacheRoot: RielaAppWorkflowRepositoryCatalogLoader.defaultCacheRoot(appRootURL: profileStore.appRootURL)
    )
  }

  func addWorkflowRepository(rawValue: String) {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      return
    }
    let repository: RielaAppWorkflowRepositoryReference
    do {
      repository = try RielaAppWorkflowRepositoryReference.parse(value)
    } catch {
      status = "Failed to add repository: \(error.localizedDescription)"
      refreshDaemonWorkflowWindow()
      return
    }
    guard !daemonState.containsWorkflowRepository(id: repository.id) else {
      status = "Repository \(repository.id) is already registered."
      refreshDaemonWorkflowWindow()
      return
    }
    let previousState = daemonState
    daemonState.addWorkflowRepository(repository)
    guard saveDaemonState() else {
      daemonState = previousState
      refreshDaemonWorkflowWindow()
      return
    }
    status = "Registered repository \(repository.id)."
    refreshDaemonWorkflowWindow()
    refreshWorkflowRepositoryCatalogs(forceRefresh: false)
  }

  func removeWorkflowRepository(id: String) {
    guard daemonState.containsWorkflowRepository(id: id) else {
      return
    }
    let previousState = daemonState
    daemonState.removeWorkflowRepository(id: id)
    guard saveDaemonState() else {
      daemonState = previousState
      refreshDaemonWorkflowWindow()
      return
    }
    marketplaceCatalogs.removeValue(forKey: id)
    marketplaceErrors.removeValue(forKey: id)
    status = "Removed repository \(id). Installed workflows were kept."
    refreshDaemonWorkflowWindow()
  }

  func refreshWorkflowRepositoryCatalogs(forceRefresh: Bool) {
    let repositories = daemonState.workflowRepositories.filter { repository in
      !marketplaceRefreshingRepositoryIds.contains(repository.id)
        && (forceRefresh || marketplaceCatalogs[repository.id] == nil)
    }
    guard !repositories.isEmpty else {
      return
    }
    let loader = marketplaceCatalogLoader
    for repository in repositories {
      marketplaceRefreshingRepositoryIds.insert(repository.id)
      marketplaceErrors.removeValue(forKey: repository.id)
      Task { @MainActor in
        let result: Result<RielaAppWorkflowRepositoryCatalog, Error> = await Task.detached {
          Result { try loader.loadCatalog(for: repository, forceRefresh: forceRefresh) }
        }.value
        marketplaceRefreshingRepositoryIds.remove(repository.id)
        switch result {
        case let .success(catalog):
          marketplaceCatalogs[repository.id] = catalog
        case let .failure(error):
          marketplaceErrors[repository.id] = error.localizedDescription
        }
        refreshDaemonWorkflowWindow(refreshesInstanceCache: false)
      }
    }
    refreshDaemonWorkflowWindow(refreshesInstanceCache: false)
  }

  func installMarketplaceWorkflow(repositoryId: String, relativePath: String) {
    guard let catalog = marketplaceCatalogs[repositoryId],
      let listing = catalog.workflows.first(where: { $0.relativePath == relativePath }) else {
      status = "Workflow listing is no longer available. Refresh the repository and retry."
      refreshDaemonWorkflowWindow()
      return
    }
    guard FileManager.default.fileExists(atPath: listing.installSourceURL.path) else {
      marketplaceCatalogs.removeValue(forKey: repositoryId)
      status = "Cached repository content is missing. Refresh the repository and retry."
      refreshDaemonWorkflowWindow()
      refreshWorkflowRepositoryCatalogs(forceRefresh: true)
      return
    }
    importDaemonWorkflowOrPackageSourcesOnly([listing.installSourceURL])
  }
}
#endif
