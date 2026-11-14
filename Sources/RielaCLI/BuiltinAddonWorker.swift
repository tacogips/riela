import Foundation
import RielaCore
import RielaKaibaAddons
import RielaKaibaSupport

/// The first-party guest entrypoint. It never creates workflow execution IDs
/// and never persists or edits runtime session records.
public enum BuiltinAddonWorker {
  public static func execute(
    _ request: BuiltinAddonContainerRequest,
    environment: [String: String],
    workingDirectory: URL,
    resolver: (any WorkflowAddonResolving)? = nil
  ) async -> BuiltinAddonContainerReply {
    do {
      try request.validate()
      if let deadline = request.deadline, deadline <= Date() {
        throw AdapterExecutionError(.timeout, "built-in container request deadline has expired")
      }
      let stateRoot = environment["RIELA_ADDON_STATE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? workingDirectory.appendingPathComponent(".riela/addon-container-state", isDirectory: true)
      let bridge: NativeAddonBridgeChannel?
      if let path = request.nativeAppleBridgeDirectory {
        let root = workingDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let directory = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard directory.path.hasPrefix(root),
              let input = request.input, AppleGatewayContainerCapability(addonName: input.addon.name).isSupported else {
          throw AdapterExecutionError(.policyBlocked, "invalid native Apple bridge scope")
        }
        bridge = try NativeAddonBridgeChannel(directory: directory)
      } else {
        bridge = nil
      }
      let nativeRunner: AppleGatewayRunner?
      if let bridge {
        nativeRunner = { arguments, _, deadline in try bridge.call(arguments: arguments, deadline: deadline) }
      } else {
        nativeRunner = nil
      }
      let selectedResolver = resolver ?? BuiltinWorkflowAddonResolver(environment: environment,
        workingDirectory: workingDirectory,
        gitExecutableURL: GitExecutablePolicy.workerURL,
        gitFinalizationStore: GitFinalizationStore(rootDirectory: stateRoot.appendingPathComponent("git-finalization", isDirectory: true)),
        appleGatewayRunner: nativeRunner)
      switch request.operation {
      case .execute:
        guard let input = request.input else { throw AdapterExecutionError(.invalidInput, "container execution input is missing") }
        guard !input.addon.name.hasPrefix("kaiba/") || request.kaibaInstance != nil else {
          throw AdapterExecutionError(.policyBlocked, "container Kaiba execution is missing its captured instance")
        }
        var snapshotEnvironment = environment
        let kaibaFactory: KaibaClientFactory
        if let path = request.nativeKaibaBridgeDirectory {
          let root = workingDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
          let directory = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
          guard directory.path.hasPrefix(root), input.addon.name.hasPrefix("kaiba/") else {
            throw AdapterExecutionError(.policyBlocked, "invalid Kaiba bridge scope")
          }
          let channel = try NativeAddonBridgeChannel(directory: directory)
          kaibaFactory = KaibaContainerGuestTransport.clientFactory { encoded, deadline in
            try channel.call(arguments: [NativeKaibaAddonBridge.operation, encoded], deadline: deadline).stdout
          }
          if let credential = request.kaibaInstance?.credentialEnvironmentVariable {
            snapshotEnvironment[credential] = "riela-host-bridge"
          }
        } else { kaibaFactory = .init() }
        let snapshot = try await KaibaExecutionPreflight.direct(addon: input.addon, environment: snapshotEnvironment,
          capturedInstance: request.kaibaInstance?.instance, clientFactory: kaibaFactory)
        let output = try await KaibaAddonExecutionContext.withSnapshot(snapshot, allowsMockExecution: false) {
          try await selectedResolver.execute(input, context: AdapterExecutionContext(deadline: request.deadline))
        }
        return .init(output: output)
      case .acknowledge:
        guard let token = request.finalizationToken,
              let acknowledger = selectedResolver as? any WorkflowAddonFinalizationAcknowledging else {
          throw AdapterExecutionError(.policyBlocked, "container worker cannot acknowledge finalization")
        }
        try await acknowledger.acknowledgeAcceptedFinalization(token)
        return .init()
      case .terminal:
        guard let workflowId = request.workflowExecutionId, let stepIds = request.stepExecutionIds,
              let recorder = selectedResolver as? any WorkflowAddonTerminalRecording else {
          throw AdapterExecutionError(.policyBlocked, "container worker cannot record terminal finalization")
        }
        try await recorder.recordTerminalFinalization(workflowExecutionId: workflowId, stepExecutionIds: stepIds)
        return .init()
      }
    } catch let error as AdapterExecutionError {
      return .init(failure: BuiltinAddonContainerFailure(error))
    } catch {
      return .init(failure: BuiltinAddonContainerFailure(
        AdapterExecutionError(.providerError, "built-in container worker failed before producing safe diagnostics")))
    }
  }

  public static func run() async {
    let reply: BuiltinAddonContainerReply
    do {
      let request = try readRequest()
      reply = await execute(request, environment: ProcessInfo.processInfo.environment,
        workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
    } catch {
      reply = .init(failure: BuiltinAddonContainerFailure(AdapterExecutionError(.invalidInput, "invalid built-in container JSONL request")))
    }
    do {
      let encoded = try JSONEncoder().encode(reply)
      guard encoded.count <= BuiltinAddonContainerRequest.maximumRecordBytes else {
        throw AdapterExecutionError(.invalidOutput, "container worker output exceeds the record size limit")
      }
      FileHandle.standardOutput.write(encoded)
      FileHandle.standardOutput.write(Data([10]))
    } catch {
      FileHandle.standardError.write(Data("failed to encode built-in container reply\n".utf8))
      Foundation.exit(1)
    }
  }

  private static func readRequest() throws -> BuiltinAddonContainerRequest {
    var bytes = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 64 * 1024), !chunk.isEmpty {
      bytes.append(chunk)
      guard bytes.count <= BuiltinAddonContainerRequest.maximumRecordBytes else {
        throw AdapterExecutionError(.invalidInput, "container request exceeds the record size limit")
      }
    }
    do {
      return try WorkerJSONLInput.decode(BuiltinAddonContainerRequest.self, from: bytes,
        framingMessage: "container worker requires one JSONL request")
    } catch is EmptyWorkerInput {
      throw AdapterExecutionError(.invalidInput, "container worker received no request bytes")
    }
  }
}
