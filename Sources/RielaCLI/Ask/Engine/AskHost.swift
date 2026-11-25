import Foundation
import RielaAppSupport
import RielaCore
import RielaObservability

struct AskHost: Sendable {
  let sessionStoreRoot: String
  let workingDirectory: String
  let scratchRoot: String
  let environment: [String: String]
  let settings: @Sendable () -> RielaAppAssistantSettings
  let readProviders: AskReadProviders
  let mutations: any AskMutationSurface
  var makeAdapter: @Sendable ([String: String]) -> any NodeAdapter = { environment in
    makeProductionNodeAdapter(environment: environment)
  }
  var limits: AskLimits = .standard
  var now: @Sendable () -> Date = Date.init
  var requiresVendorAvailability = true
  var rielaExecutablePath: String?
  var scope: WorkflowScope?

  var store: BotStore {
    BotStore(sessionStoreRoot: sessionStoreRoot)
  }

  func turnDirectory(conversationId: String, turnId: String) -> URL? {
    guard conversationId.hasPrefix("ask-"), UUID(uuidString: String(conversationId.dropFirst(4))) != nil,
          turnId.hasPrefix("turn-"), let number = Int(turnId.dropFirst(5)), number > 0 else { return nil }
    return URL(fileURLWithPath: scratchRoot, isDirectory: true)
      .appendingPathComponent("\(conversationId)-\(turnId)", isDirectory: true)
  }

  func removeTurnArtifact(_ artifact: URL) {
    do {
      try FileManager.default.removeItem(at: artifact)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    } catch {
      let detail = AskRedaction.text(String(describing: error), environment: environment)
      RielaStandardStreams.writeError("riela ask scratch cleanup: \(detail)\n")
    }
  }

  func scriptingAdapter() throws -> AskScriptedBackend? {
    guard let path = environment[AskScriptedBackend.environmentKey], !path.isEmpty else { return nil }
    let url = absoluteURL(path, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true))
    guard FileManager.default.isReadableFile(atPath: url.path),
          try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
    return try AskScriptedBackend(fileURL: url)
  }

  func actionService() -> AskActionService {
    let proposals = AskActionProposer(
      surface: ProviderAskReadSurface(providers: readProviders), store: store,
      environment: environment, limits: limits, now: now
    )
    return AskActionService(store: store, proposals: proposals, mutations: mutations, environment: environment, now: now)
  }

  func toolExecutor(recorder: any WorkflowActivityRecording) -> AskToolExecutor {
    let surface = ProviderAskReadSurface(providers: readProviders)
    return AskToolExecutor(
      store: store, surface: surface, proposals: AskActionProposer(
        surface: surface, store: store, environment: environment, limits: limits, now: now
      ), recorder: recorder, environment: environment, limits: limits, now: now
    )
  }
}
