import Foundation
import RielaAddonSupport
import RielaCore
import XGatewayCore

/// The read-only X SDK executes in this process, including inside a private
/// workflow guest. It never launches a gateway CLI or another container.
extension BuiltinWorkflowAddonResolver {
  func executeXGatewaySDKAddon(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    let deadline = context.deadline
    let document = try builtinGatewayXJSONDocument(input)
    let userCache = try XGatewayUserCacheExchange(input: input, environment: environment)
    let usageCache = try XGatewayUsageCacheExchange(input: input, environment: environment)
    let descriptor = LocalGatewayGraphQLDescriptor(providerName: "x-gateway", payloadNamespaceKey: "xGateway",
      tier: "x-gateway-reader", acceptsVariables: false,
      isAllowedEnvironmentTarget: { xGatewayReaderCredentialEnvironment.contains($0) },
      observationMetadata: xGatewayUsageMetadata,
      run: { _, document, _, environment in
        let sdk = XGatewayReaderSDK.invocationOverride ?? XGatewayReaderSDK.live
        // The SDK blocks its thread for every HTTP request. Keep it (and the
        // SQLite cache I/O around it) off Swift's cooperative pool; on the step
        // deadline the caller is cancelled and the late result is discarded.
        return try await xGatewayRunOffCooperativePool {
          let bindings = try userCache?.bindings() ?? [:]
          return try xGatewayReaderQuery(document: document,
            environment: environment.merging(bindings) { _, memory in memory },
            deadline: deadline, userCache: userCache, usageCache: usageCache, sdk: sdk)
        }
      })
    return try await LocalGatewayGraphQLEngine(environment: environment, descriptor: descriptor,
      runnerOverride: localGatewayGraphQLRunner).execute(input, context: context, documentOverride: document)
  }
}

func xGatewayUsageMetadata(_ stdout: String) -> JSONObject {
  guard let graphQL = XGatewayUsageCacheExchange.decodeBoundedEnvelope(stdout),
        case let .object(extensions)? = graphQL["extensions"] else { return [:] }
  var result: JSONObject = [:]
  if let raw = extensions["resourceUsage"], let normalized = XGatewayUsageObservation.normalized(raw) {
    result["resourceUsage"] = normalized
  }
  if let status = nonEmptyString(extensions["usageCacheStatus"]),
     XGatewayUsageCacheExchange.Status(rawValue: status) != nil {
    result["usageCacheStatus"] = .string(status)
  }
  if let status = nonEmptyString(extensions["userCacheStatus"]), XGatewayUserCacheExchange.statuses.contains(status) {
    result["userCacheStatus"] = .string(status)
  }
  return result
}

/// The only addon.env targets either X reader (embedded or container) accepts.
/// Transport controls such as `X_GW_RETRY`, `X_GW_TIMEOUT_MS` and
/// `X_GW_MEDIA_ROOT_DIR` stay owned by the runtime.
let xGatewayReaderCredentialEnvironment: Set<String> = [
  "X_GW_TOKEN", "X_GW_APP_TOKEN", "X_GW_CONSUMER_KEY", "X_GW_CONSUMER_SECRET",
  "X_GW_ACCESS_TOKEN", "X_GW_ACCESS_TOKEN_SECRET"
]

struct XGatewayReaderSDKResult: Sendable {
  var exitCode: Int32
  var stdout: String
  var stderr: String
}

typealias XGatewayReaderSDKInvocation = @Sendable (_ arguments: [String], _ environment: [String: String]) -> XGatewayReaderSDKResult

/// Shared X reader transport contract for the embedded SDK and the reader container.
enum XGatewayReaderSDK {
  /// Upper bound for one HTTP request. `--timeout-ms` is per request, not per
  /// GraphQL operation: one query can issue several requests (expansions,
  /// references, user-cache author lookups).
  static let maximumRequestTimeoutMilliseconds = 30_000

  static let live: XGatewayReaderSDKInvocation = { arguments, environment in
    let result = XGatewayCLI(commandName: "x-gateway-reader", surface: .read).run(arguments: arguments, environment: environment)
    return XGatewayReaderSDKResult(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
  }

  /// Test seam for the real embedded `run` path; nil uses the linked SDK.
  @TaskLocal static var invocationOverride: XGatewayReaderSDKInvocation?

  /// Reader arguments: no SDK retries (the workflow owns retry/pagination so paid
  /// reads are not multiplied) and a per-request timeout bounded by the deadline.
  static func arguments(document: String, deadline: Date?, now: Date = Date()) -> [String] {
    let ceiling = maximumRequestTimeoutMilliseconds
    let remaining = deadline.map { $0.timeIntervalSince(now) * 1000 } ?? Double(ceiling)
    let milliseconds = max(1, Int(min(Double(ceiling), remaining)))
    return ["graphql", "query", document, "--json", "--retry", "0", "--timeout-ms", String(milliseconds)]
  }
}

/// Runs blocking work on a dedicated thread so it cannot park a cooperative-pool
/// thread. Cancellation (the node deadline in `localGatewayRunWithDeadline`)
/// resumes the caller immediately; the abandoned work finishes in the background
/// and its result is ignored.
func xGatewayRunOffCooperativePool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
  let gate = XGatewayBlockingCallGate<T>()
  return try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
      guard gate.install(continuation) else { return }
      let thread = Thread { gate.finish(Result { try work() }) }
      thread.name = "riela.x-gateway-reader"
      thread.stackSize = 4 << 20
      thread.start()
    }
  } onCancel: {
    gate.finish(.failure(CancellationError()))
  }
}

private final class XGatewayBlockingCallGate<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, Error>?
  private var outcome: Result<T, Error>?
  private var finished = false

  /// Returns false when the call already finished (cancelled before it started).
  func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
    let early: Result<T, Error>? = lock.withLock {
      if finished { return outcome }
      self.continuation = continuation
      return nil
    }
    guard let early else { return true }
    continuation.resume(with: early)
    return false
  }

  func finish(_ result: Result<T, Error>) {
    let pending: CheckedContinuation<T, Error>? = lock.withLock {
      guard !finished else { return nil }
      finished = true
      outcome = result
      defer { continuation = nil }
      return continuation
    }
    pending?.resume(with: result)
  }
}

/// The in-process reader writes with the riela process's permissions, so a
/// document may not choose a media download directory. `downloadMedia` and
/// `forceDownload` stay accepted: without a media root (the embedded reader never
/// forwards `X_GW_MEDIA_ROOT_DIR`) the SDK keeps media as source URLs.
func xGatewayRejectHostMediaArguments(_ document: String) throws {
  if xGraphQLNameTokens(document).contains("mediaRootDir") {
    throw AdapterExecutionError(.policyBlocked, "X reader does not accept mediaRootDir; media stays source-URL only")
  }
}

/// GraphQL name tokens outside string literals and comments.
private func xGraphQLNameTokens(_ document: String) -> Set<String> {
  let bytes = Array(document.utf8)
  var names = Set<String>()
  var index = 0
  func isNameStart(_ byte: UInt8) -> Bool { byte == 95 || (65...90).contains(byte) || (97...122).contains(byte) }
  func isNameByte(_ byte: UInt8) -> Bool { isNameStart(byte) || (48...57).contains(byte) }
  func hasBlockQuote(at offset: Int) -> Bool {
    offset + 2 < bytes.count && bytes[offset] == 34 && bytes[offset + 1] == 34 && bytes[offset + 2] == 34
  }
  while index < bytes.count {
    let byte = bytes[index]
    if byte == 35 {
      while index < bytes.count, bytes[index] != 10, bytes[index] != 13 { index += 1 }
    } else if hasBlockQuote(at: index) {
      index += 3
      while index < bytes.count, !hasBlockQuote(at: index) {
        index += bytes[index] == 92 && hasBlockQuote(at: index + 1) ? 4 : 1
      }
      index += 3
    } else if byte == 34 {
      index += 1
      while index < bytes.count, bytes[index] != 34, bytes[index] != 10 {
        index += bytes[index] == 92 ? 2 : 1
      }
      index += 1
    } else if isNameStart(byte) {
      let start = index
      while index < bytes.count, isNameByte(bytes[index]) { index += 1 }
      names.insert(String(bytes: bytes[start..<index], encoding: .utf8) ?? "")
    } else {
      index += 1
    }
  }
  return names
}

func xGatewayReaderQuery(document: String, environment: [String: String], deadline: Date?,
                         userCache: XGatewayUserCacheExchange? = nil,
                         usageCache: XGatewayUsageCacheExchange? = nil,
                         sdk: XGatewayReaderSDKInvocation = XGatewayReaderSDK.live) throws -> String {
  guard (try? XGatewayCLI.classifyGraphQLOperation(document)) == .query else {
    throw AdapterExecutionError(.policyBlocked, "X reader requires a query operation")
  }
  try xGatewayRejectHostMediaArguments(document)
  if let deadline, deadline.timeIntervalSinceNow <= 0 {
    throw AdapterExecutionError(.timeout, "X reader deadline expired")
  }
  // No SDK retry; the timeout bounds each HTTP request. The caller enforces the
  // node deadline for the whole operation and abandons a late SDK call.
  let result = sdk(XGatewayReaderSDK.arguments(document: document, deadline: deadline), environment)
  // Decode each stream once; usage telemetry, the user cache and the result
  // guard all read the same object.
  let stdoutEnvelope = XGatewayUsageCacheExchange.decodeBoundedEnvelope(result.stdout)
  let stderrEnvelope = result.stderr.isEmpty ? nil : XGatewayUsageCacheExchange.decodeBoundedEnvelope(result.stderr)
  let usageStatus = usageCache?.record(envelopes: [stdoutEnvelope, stderrEnvelope].compactMap { $0 }, environment: environment)
  var envelope = result.exitCode == 0 ? stdoutEnvelope : nil
  if let current = envelope, let userCache { envelope = try userCache.consume(envelope: current) }
  guard let envelope, envelope["ok"] == .bool(true), case var .object(graphQL)? = envelope["data"] else {
    // Provider diagnostics may contain private source data; the worker keeps
    // them out of the enclosing workflow's error/result channel.
    throw AdapterExecutionError(.providerError, "X reader SDK query failed"
      + (usageStatus.map { " usageCacheStatus=\($0.rawValue)" } ?? "")
      + GatewayFailureDiagnostics.suffix(stdout: result.stdout, stderr: result.stderr))
  }
  if let usageStatus {
    var extensions: JSONObject = [:]
    if case let .object(current)? = graphQL["extensions"] { extensions = current }
    extensions["usageCacheStatus"] = .string(usageStatus.rawValue)
    graphQL["extensions"] = .object(extensions)
  }
  return try JSONValue.object(graphQL).compactJSONString()
}
