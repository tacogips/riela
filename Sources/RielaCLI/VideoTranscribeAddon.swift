import Foundation
import RielaAdapters
import RielaAddonSupport
import RielaCore

extension BuiltinWorkflowAddonResolver {
  static let videoTranscribeRegistration = BuiltinAddonHandlerRegistration(name: "riela/video-transcribe", bindsCLIVariablesAsInputs: false) { resolver, input, context in
    try await resolver.executeVideoTranscribe(input, context: context)
  }

  func executeVideoTranscribe(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    do {
      guard input.addon.version == nil || input.addon.version == "1",
        case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: addonVariables(for: input)),
        Set(config.keys).isSubset(of: ["options", "context"]), case let .object(values)? = config["options"],
        try JSONEncoder().encode(config).count <= 8_000_000 else { throw VideoTranscribeError.invalidOptions }
      let options = try VideoTranscribeOptions(values, workingDirectory: workingDirectory)
      guard Set(input.addon.env?.keys.map { $0 } ?? []).isSubset(of: ["OPENAI_API_KEY", "OPENAI_BASE_URL"]) else {
        throw AdapterExecutionError(.policyBlocked, "video-transcribe addon.env supports OPENAI_API_KEY and OPENAI_BASE_URL only")
      }
      let credentials = try resolveAddonEnvironment(input.addon.env, runtimeEnvironment: environment)
      guard let apiKey = credentials["OPENAI_API_KEY"], !apiKey.isEmpty else {
        throw AdapterExecutionError(.policyBlocked, "video-transcribe requires addon.env.OPENAI_API_KEY")
      }
      let service = VideoTranscribeService(runner: containerProcessRunner, workingDirectory: workingDirectory,
        artifactRoot: URL(fileURLWithPath: environment["RIELA_ARTIFACT_DIR"] ?? workingDirectory.appendingPathComponent(".riela/artifacts").path),
        http: videoTranscribeNativeHTTP, resolverEnvironment: environment)
      let payload = try await service.collect(options: options, apiKey: apiKey,
        baseURL: credentials["OPENAI_BASE_URL"] ?? "https://api.openai.com", deadline: context.deadline)
      guard try JSONEncoder().encode(payload).count <= 8_000_000 else { throw AdapterExecutionError(.invalidInput, "video-transcribe output exceeds 8 MB") }
      return .init(provider: "riela-builtin-addon", model: input.addon.name, promptText: "", completionPassed: true,
        when: ["always": true], payload: payload)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as AdapterExecutionError {
      throw error
    } catch VideoTranscribeError.invalidOptions {
      throw AdapterExecutionError(.invalidInput, "invalid video-transcribe options")
    } catch VideoTranscribeError.invalidOption(let option) {
      throw AdapterExecutionError(.invalidInput, "invalid video-transcribe option '\(option)'")
    } catch VideoTranscribeError.unsupportedProvider(let provider) {
      throw AdapterExecutionError(.invalidInput, "video-transcribe STT provider '\(provider)' is unsupported; use openai")
    } catch VideoTranscribeError.stage(let stage, let message) {
      throw AdapterExecutionError(.providerError, "video-transcribe \(stage) failed: \(message)")
    } catch {
      throw AdapterExecutionError(.providerError, "video-transcribe processing failed")
    }
  }
}
