import CRielaPrivateWorker
import Foundation
import RielaCore
#if os(Linux)
import Glibc
#endif

enum PrivateWorkflowWorker {
  static let command = "__riela-private-workflow-worker"
  /// `_exit` status of the pre-main shim (CRielaPrivateWorker.c) when the guest
  /// identity or process limits are unacceptable.
  static let guestRefusalStatus: Int32 = 112
  /// The inner run's timer is derived from the outer deadline and truncated to
  /// milliseconds, so it can fire marginally before that deadline.
  static let deadlineTolerance: TimeInterval = 0.25

  static func run() async {
    let writer = SandboxNodeRecordWriter()
    let operation = Task {
      do {
        // Check the boundary before reading any credential or private input.
        try verifyGuest(maximumTemporaryMiB: 4096)
        let request = try readRequest()
        guard request.version == PrivateWorkflowRequest.currentVersion else {
          var record = SandboxNodeRecord(kind: .failure, failure: .init(.init(.policyBlocked,
            "private workflow execution failed")))
          if request.version < PrivateWorkflowRequest.currentVersion { record.version = 1 }
          writer.emit(record)
          return
        }
        try request.plan.validate()
        try verifyGuest(maximumTemporaryMiB: request.plan.temporaryStorageMiB ?? 256)
        try PrivateWorkflowPlan.validateEnvironment(request.environment)
        try SandboxNodeWorker.preparePrivateHome(credentials: request.credentials)
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? "")
        let root = home.deletingLastPathComponent()
        #if os(Linux)
        for (name, value) in request.environment { setenv(name, value, 1) }
        setenv("RIELA_MEMORY_ROOT", root.appendingPathComponent("memory").path, 1)
        if let names = request.plan.cacheSpaces, !names.isEmpty {
          setenv("RIELA_CACHE_ROOT", root.appendingPathComponent("cache").path, 1)
          let spaces = PrivateWorkflowCacheSpaces(names: names, environment: ProcessInfo.processInfo.environment)
          spaces.seed(request.cacheSeeds ?? [:])
          setenv(PrivateWorkflowCacheTransport.environmentKey, names.joined(separator: ","), 1)
        }
        if request.plan.xUsageScope != nil { setenv("RIELA_X_USAGE_EXPORT", "1", 1) }
        #endif
        let result = try await executeWorkflow(request, root: root)
        writer.emit(.init(kind: .result, output: result))
      } catch {
        writer.emit(.init(kind: .failure, failure: .init(failure(for: error))))
      }
    }
    let cancellation = CLISignalCancellation { _ in operation.cancel() }
    await operation.value
    cancellation.cancel()
  }

  /// Finite code, fixed text: inner diagnostics never cross the boundary.
  static func failure(for error: Error) -> AdapterExecutionError {
    if error is EmptyWorkerInput { return .init(.invalidInput, WorkerJSONLInput.privateEmptyMessage) }
    let code: AdapterExecutionErrorCode
    switch error {
    case let error as PrivateWorkflowExecutionFailure:
      return .init(error.code, error.diagnostic.message)
    case let error as AdapterExecutionError: code = error.code
    case WorkflowPublicationError.validationRejected: code = .invalidOutput
    default: code = .providerError
    }
    return .init(code, "private workflow execution failed")
  }

  /// Embedded Riela owns dispatch/fanout, model execution and builtin calls.
  /// Inner sessions/artifacts exist only under the guest's temporary root.
  static func executeWorkflow(_ request: PrivateWorkflowRequest, root: URL) async throws -> AdapterExecutionOutput {
    try request.plan.validate()
    let milliseconds = Int(min(3600, request.deadline.timeIntervalSinceNow) * 1000)
    guard milliseconds > 0 else { throw AdapterExecutionError(.timeout, "private workflow deadline expired") }
    let work = root.appendingPathComponent("work")
    for name in ["work", "sessions", "artifacts", "memory"] {
      try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
    let resolution = WorkflowResolutionOptions(workflowName: request.plan.workflowId,
      workflowDefinitionDir: request.plan.definitionRoot, workingDirectory: work.path)
    var command = WorkflowRunCommand()
    command.outputProjection = rootResult
    let result = await command.runWithoutSpecialistMonitor(.init(target: request.plan.workflowId,
      resolution: resolution, variables: try JSONValue.object(request.plan.variables).compactJSONString(), output: .json,
      maxSteps: request.plan.maxSteps ?? 1000, maxConcurrency: request.plan.maxConcurrency ?? 4,
      maxLoopIterations: 1000, timeoutMs: milliseconds,
      sessionStore: root.appendingPathComponent("sessions").path, workingDirectory: work.path))
    let bytes = result.stdout.data(using: .utf8) ?? Data()
    let envelope: JSONObject? = bytes.count <= BuiltinAddonContainerRequest.maximumRecordBytes
      ? (try? JSONDecoder().decode(JSONObject.self, from: bytes)) : nil
    guard result.exitCode == .success, case let .object(payload)? = envelope?["rootOutput"] else {
      // A timed-out inner graph keeps the timeout class so the outer step's
      // nodeTimeout retry policy can apply.
      let timedOut = envelope?["failureKind"] == .string(WorkflowSessionFailureKind.nodeTimeout.rawValue)
        || request.deadline.timeIntervalSinceNow <= deadlineTolerance
      let code: AdapterExecutionErrorCode = timedOut ? .timeout : .providerError
      if let stages = request.plan.failureStages, !stages.isEmpty,
         case let .string(sessionId)? = envelope?["sessionId"],
         let snapshot = try? SQLiteWorkflowRuntimePersistenceStore(rootDirectory:
           canonicalRuntimeStoreRoot(sessionStoreRoot: root.appendingPathComponent("sessions").path)).load(sessionId: sessionId),
         let step = snapshot.session.currentStepId, let stage = stages[step],
         let kind = snapshot.session.failureKind {
        let publicKind = PrivateWorkflowFailureDiagnostic.allowedKinds.contains(kind.rawValue) ? kind.rawValue : "other"
        throw PrivateWorkflowExecutionFailure(code: code,
          diagnostic: .init(stage: stage, kind: publicKind))
      }
      throw AdapterExecutionError(code, "private inner workflow did not complete")
    }
    let output = AdapterExecutionOutput(provider: "riela-private-workflow", model: request.plan.workflowId,
      promptText: "", completionPassed: true, payload: payload)
    return try SandboxNodeWorker.privateOutput(output, contract: .init(jsonSchema: request.plan.outputSchema))
  }

  /// Only the declared root and finite lifecycle metadata leave embedded
  /// execution. Full sessions remain in the canonical guest runtime store.
  static func rootResult(_ result: WorkflowRunResult) -> JSONObject {
    ["rootOutput": result.rootOutput.map(JSONValue.object) ?? .null,
     "sessionId": .string(result.session.sessionId), "status": .string(result.status.rawValue),
     "exitCode": .integer(Int64(result.exitCode)),
     "failureKind": result.session.failureKind.map { .string($0.rawValue) } ?? .null]
  }

  static func verifyGuest(maximumTemporaryMiB: Int = 256) throws {
    #if os(Linux)
    guard riela_private_worker_prepared() == 1 else { throw PrivateWorkflowPlan.invalid() }
    let taskRoot = URL(fileURLWithPath: "/proc/self/task")
    let status = try FileManager.default.contentsOfDirectory(at: taskRoot, includingPropertiesForKeys: nil)
      .map { try String(contentsOf: $0.appendingPathComponent("status"), encoding: .utf8) }
    let mounts = try String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8)
    var stats = statvfs()
    guard statvfs("/tmp", &stats) == 0 else { throw PrivateWorkflowPlan.invalid() }
    let (bytes, overflow) = UInt64(stats.f_blocks).multipliedReportingOverflow(by: UInt64(stats.f_frsize))
    guard !overflow else { throw PrivateWorkflowPlan.invalid() }
    try verifyGuestMetadata(status: status, mounts: mounts, temporaryBytes: bytes,
      maximumTemporaryMiB: maximumTemporaryMiB)
    #else
    throw AdapterExecutionError(.policyBlocked, "private workflow worker requires a Linux container")
    #endif
  }

  static func verifyGuestMetadata(status: [String], mounts: String, temporaryBytes: UInt64,
    maximumTemporaryMiB: Int = 256) throws {
    guard (64...4096).contains(maximumTemporaryMiB), !status.isEmpty, temporaryBytes > 0,
      temporaryBytes <= UInt64(maximumTemporaryMiB) * 1024 * 1024 else { throw PrivateWorkflowPlan.invalid() }
    for text in status {
      var fields: [String: String] = [:]
      for line in text.split(separator: "\n") {
        let pair = line.split(separator: ":", maxSplits: 1)
        guard pair.count == 2, fields[String(pair[0])] == nil else { throw PrivateWorkflowPlan.invalid() }
        fields[String(pair[0])] = pair[1].trimmingCharacters(in: .whitespaces)
      }
      guard fields["NoNewPrivs"] == "1", ["CapEff", "CapPrm", "CapBnd", "CapAmb"].allSatisfy({
        fields[$0].flatMap { UInt64($0, radix: 16) } == 0
      }) else { throw PrivateWorkflowPlan.invalid() }
    }
    let rows = mounts.split(separator: "\n").map { $0.split(separator: " ") }
    let temporary = rows.first { $0.count > 6 && $0[4] == "/tmp" }
    let root = rows.first { $0.count > 6 && $0[4] == "/" }
    guard let temporary, let root, let separator = temporary.firstIndex(of: "-"), separator + 1 < temporary.count,
          temporary[separator + 1] == "tmpfs", root[5].split(separator: ",").contains("ro"),
          Set(["rw", "nosuid", "nodev", "noexec"]).isSubset(of: Set(temporary[5].split(separator: ",").map(String.init))) else {
      throw PrivateWorkflowPlan.invalid()
    }
  }

  private static func readRequest() throws -> PrivateWorkflowRequest {
    var bytes = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 64 * 1024), !chunk.isEmpty {
      bytes.append(chunk)
      guard bytes.count <= BuiltinAddonContainerRequest.maximumRecordBytes else { throw PrivateWorkflowPlan.invalid() }
    }
    return try WorkerJSONLInput.decode(PrivateWorkflowRequest.self, from: bytes,
      framingMessage: "private workflow worker requires one JSONL request")
  }
}
