import Foundation
import RielaCore
@testable import RielaCLI

/// Stands in for a gateway's GraphQL runtime in add-on tests. The gateways are
/// linked into this process, so an add-on test that reached the real runtime
/// would need a live account; recording the call instead keeps the assertions
/// on what riela is responsible for — the tier it pinned, the document and
/// variables it rendered, and the environment it let the gateway see.
final class RecordingGatewayGraphQLRunner: @unchecked Sendable {
  struct Call: Sendable {
    var tier: String
    var document: String
    var variablesJSON: String?
    var environment: [String: String]
  }

  private let lock = NSLock()
  private let response: String
  private let failure: (any Error)?
  private var calls: [Call] = []

  init(response: String = "{}", failure: (any Error)? = nil) {
    self.response = response
    self.failure = failure
  }

  var runner: LocalGatewayGraphQLRunner {
    { [self] tier, document, variablesJSON, environment in
      lock.withLock {
        calls.append(Call(
          tier: tier,
          document: document,
          variablesJSON: variablesJSON,
          environment: environment
        ))
      }
      if let failure { throw failure }
      return response
    }
  }

  func lastCall() -> Call? { lock.withLock { calls.last } }
  func allCalls() -> [Call] { lock.withLock { calls } }
}

/// The same seam for google-documents-gateway, whose surface is CLI arguments
/// rather than a GraphQL document.
final class RecordingGoogleDocumentsGatewayRunner: @unchecked Sendable {
  struct Call: Sendable {
    var tier: String
    var arguments: [String]
    var environment: [String: String]
  }

  private let lock = NSLock()
  private let response: String
  private let failure: (any Error)?
  private var calls: [Call] = []

  init(response: String = #"{"ok":true,"data":{}}"#, failure: (any Error)? = nil) {
    self.response = response
    self.failure = failure
  }

  var runner: GoogleDocumentsGatewayRunner {
    { [self] tier, arguments, environment in
      lock.withLock {
        calls.append(Call(tier: tier, arguments: arguments, environment: environment))
      }
      if let failure { throw failure }
      return response
    }
  }

  func lastCall() -> Call? { lock.withLock { calls.last } }
  func allCalls() -> [Call] { lock.withLock { calls } }
}

/// Runs an executable stand-in for apple-gateway.
///
/// apple-gateway is linked into riela and drives the machine's real Notes,
/// Mail, Calendars, and Reminders, so add-on tests must not reach it. The
/// stand-in scripts these tests write are still spawned — that is what keeps
/// their canned responses and argument/environment logs — but only through
/// this seam, which production never installs.
func appleGatewayStandIn(_ executableURL: URL) -> AppleGatewayRunner {
  { arguments, environment, deadline in
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    do {
      try process.run()
    } catch {
      throw AdapterExecutionError(.providerError, "apple-gateway stand-in failed to start: \(error)")
    }
    // A stand-in that hangs must not hang the suite; the real gateway is a
    // linked call and simply runs to completion.
    let timeout = deadline.map { deadline -> DispatchWorkItem in
      let item = DispatchWorkItem { if process.isRunning { process.terminate() } }
      DispatchQueue.global().asyncAfter(
        deadline: .now() + max(0, deadline.timeIntervalSinceNow),
        execute: item
      )
      return item
    }
    // Both pipes are drained concurrently: a stand-in that writes a lot to
    // stderr would otherwise fill that pipe and block while this thread is
    // still reading stdout.
    let stderrBuffer = CollectedPipeData()
    let stderrDrain = Thread { stderrBuffer.store(error.fileHandleForReading.readDataToEndOfFile()) }
    stderrDrain.start()
    let stdoutData = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    while !stderrBuffer.isFinished { usleep(1_000) }
    let stderrData = stderrBuffer.data
    timeout?.cancel()
    return AppleGatewayProcessOutput(
      stdout: String(data: stdoutData, encoding: .utf8) ?? "",
      stderr: String(data: stderrData, encoding: .utf8) ?? "",
      terminationStatus: process.terminationStatus
    )
  }
}

/// Pulls the stand-in gateway path out of an add-on config so tests keep
/// declaring it the way they always did, while production keeps refusing
/// `config.binaryPath` — there is no gateway executable any more.
func splitAppleGatewayStandIn(_ config: JSONObject) -> (config: JSONObject, runner: AppleGatewayRunner) {
  guard case let .string(path)? = config["binaryPath"] else {
    // Fail closed. Without a stand-in the add-on would call the linked
    // gateway, which reads the machine's real Notes, Mail, and Calendars and
    // can block on a permission prompt.
    return (config, { _, _, _ in
      throw AdapterExecutionError(
        .providerError,
        "test installed no apple-gateway stand-in; set config.binaryPath in the test"
      )
    })
  }
  var stripped = config
  stripped["binaryPath"] = nil
  return (stripped, appleGatewayStandIn(URL(fileURLWithPath: path)))
}

private final class CollectedPipeData: @unchecked Sendable {
  private let lock = NSLock()
  private var collected = Data()
  private var finished = false

  func store(_ value: Data) {
    lock.withLock {
      collected = value
      finished = true
    }
  }

  var data: Data { lock.withLock { collected } }
  var isFinished: Bool { lock.withLock { finished } }
}
