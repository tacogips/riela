import Foundation
import RielaCore
@testable import RielaAppSupport
import XCTest

private actor EnvironmentRunnerStub: RuntimeEnvironmentCommandRunning {
  var outputs: [Result<Data, RuntimeEnvironmentError>]
  var calls = 0
  var delay: UInt64
  init(_ outputs: [Result<Data, RuntimeEnvironmentError>], delay: UInt64 = 0) { self.outputs = outputs; self.delay = delay }
  func run(source: RuntimeEnvironmentCommandSource, baseEnvironment: [String: String], maxOutputBytes: Int) async throws -> Data {
    calls += 1
    if delay > 0 { try await Task.sleep(nanoseconds: delay) }
    return try outputs.removeFirst().get()
  }
  func count() -> Int { calls }
}

final class RuntimeEnvironmentSnapshotStoreTests: XCTestCase {
  func testErrorsRenderOnlyStableSafeCodes() {
    let errors: [RuntimeEnvironmentError] = [.notPrepared, .invalidConfiguration, .sourceFailed,
      .sourceTimeout, .outputTooLarge, .outputInvalid, .requiredMissing, .restartRequired, .reloadInProgress, .instanceChanged]
    for error in errors {
      XCTAssertEqual(String(describing: error), error.rawValue)
      XCTAssertEqual(error.localizedDescription, error.rawValue)
    }
    XCTAssertEqual(String(describing: RuntimeEnvironmentError.requiredMissing), "environment_required_missing")
    XCTAssertEqual(RuntimeEnvironmentError.restartRequired.rawValue, "environment_restart_required")
    XCTAssertEqual(RuntimeEnvironmentError.reloadInProgress.rawValue, "environment_reload_in_progress")
    XCTAssertEqual(RuntimeEnvironmentError.instanceChanged.rawValue, "environment_instance_changed")
  }

  private let scope = RuntimeEnvironmentScope(profile: "default", instanceIdentity: "fixture")
  private func configuration(_ format: RuntimeEnvironmentCommandSource.Format = .json) -> RuntimeEnvironmentConfiguration {
    RuntimeEnvironmentConfiguration(required: ["TOKEN"], sources: [
      RuntimeEnvironmentCommandSource(id: "fixture", names: ["TOKEN"], command: ["/fixture"], format: format)
    ])
  }

  func testPrepareOnceReloadAtomicAndSecretFreeStatus() async throws {
    let canary = "synthetic-secret-canary-never-persist"
    let runner = EnvironmentRunnerStub([.success(Data("{\"TOKEN\":\"\(canary)\"}".utf8)), .failure(.sourceFailed), .success(Data("{\"TOKEN\":\"next\"}".utf8))])
    let store = RuntimeEnvironmentSnapshotStore(runner: runner)
    let first = try await store.prepare(scope: scope, configuration: configuration(), requiredNames: [], baseEnvironment: ["HOME": "/fixture"])
    let cached = try await store.prepare(scope: scope, configuration: configuration(), requiredNames: [], baseEnvironment: ["HOME": "/fixture"])
    XCTAssertEqual(first.generation, cached.generation)
    let calls = await runner.count(); XCTAssertEqual(calls, 1)
    XCTAssertEqual(first.runtimeEnvironment()["TOKEN"], canary)
    do { _ = try await store.reload(scope: scope, configuration: configuration(), requiredNames: [], baseEnvironment: [:]); XCTFail("reload must fail") } catch {
      XCTAssertEqual(error as? RuntimeEnvironmentError, .sourceFailed) }
    let retained = try await store.capture(scope: scope); XCTAssertEqual(retained.runtimeEnvironment()["TOKEN"], canary)
    let status = await store.status(scope: scope); XCTAssertEqual(status.readiness, .ready); XCTAssertEqual(status.lastError, .sourceFailed)
    XCTAssertFalse((String(bytes: try JSONEncoder().encode(status), encoding: .utf8) ?? "encoding-failed").contains(canary))
    XCTAssertFalse(String(reflecting: first).contains(canary))
    XCTAssertFalse(String(describing: first.customMirror.children.map(\.value)).contains(canary))
    _ = try await store.reload(scope: scope, configuration: configuration(), requiredNames: [], baseEnvironment: [:])
    let next = try await store.capture(scope: scope); XCTAssertEqual(next.generation, 2)
    XCTAssertEqual(next.runtimeEnvironment()["TOKEN"], "next")
    XCTAssertEqual(first.runtimeEnvironment()["TOKEN"], canary)
  }

  func testInitialMissingAndChangedDescriptorBlockCapture() async throws {
    let runner = EnvironmentRunnerStub([.success(Data("{}".utf8)), .success(Data("{\"TOKEN\":\"old\"}".utf8)), .failure(.sourceFailed)])
    let store = RuntimeEnvironmentSnapshotStore(runner: runner)
    do { _ = try await store.prepare(scope: scope, configuration: configuration(), requiredNames: [], baseEnvironment: [:]); XCTFail("missing") } catch {
      XCTAssertEqual(error as? RuntimeEnvironmentError, .requiredMissing) }
    let missing = await store.status(scope: scope); XCTAssertEqual(missing.missingNames, ["TOKEN"])
    do { _ = try await store.capture(scope: scope); XCTFail("initial failure must block") } catch {}
    _ = try await store.prepare(scope: scope, configuration: configuration(), requiredNames: [], baseEnvironment: [:])
    var changed = configuration(); changed.sources[0].command = ["/changed"]
    do { _ = try await store.prepare(scope: scope, configuration: changed, requiredNames: [], baseEnvironment: [:]); XCTFail("changed source fails") } catch {}
    do { _ = try await store.capture(scope: scope); XCTFail("old descriptor must not remain usable") } catch {}
  }

  func testConcurrentPrepareSharesLoaderAndNewBaseDoesNotReloadSecrets() async throws {
    let runner = EnvironmentRunnerStub([.success(Data("{\"TOKEN\":\"cached-secret\"}".utf8))], delay: 30_000_000)
    let store = RuntimeEnvironmentSnapshotStore(runner: runner)
    let scope = self.scope
    let config = configuration()
    async let first = store.prepare(scope: scope, configuration: config, requiredNames: [], baseEnvironment: ["CONFIG_PATH": "old"])
    async let second = store.prepare(scope: scope, configuration: config, requiredNames: [], baseEnvironment: ["CONFIG_PATH": "old"])
    let both = try await [first, second]
    XCTAssertEqual(both.map(\.generation), [1, 1])
    let rebased = try await store.prepare(scope: scope, configuration: configuration(), requiredNames: [], baseEnvironment: ["CONFIG_PATH": "new", "TOKEN": "untrusted-base"])
    XCTAssertEqual(rebased.runtimeEnvironment()["CONFIG_PATH"], "new")
    XCTAssertEqual(rebased.runtimeEnvironment()["TOKEN"], "cached-secret")
    XCTAssertEqual(rebased.generation, 2)
    let calls = await runner.count(); XCTAssertEqual(calls, 1)
    let whitespace = RuntimeEnvironmentSnapshotStore(runner: EnvironmentRunnerStub([.success(Data("{\"TOKEN\":\" \\n\"}".utf8))]))
    do { _ = try await whitespace.prepare(scope: scope, configuration: configuration(), requiredNames: [], baseEnvironment: [:]); XCTFail("whitespace required value") } catch {
      XCTAssertEqual(error as? RuntimeEnvironmentError, .requiredMissing) }
  }

  func testCancellationCleansOwnedProcessGroup() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appendingPathComponent("tmp/environment-runner-tests/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("child.pid")
    let source = RuntimeEnvironmentCommandSource(id: "cancel", names: ["TOKEN"], command: ["/bin/sh", "-c",
      "sleep 20 & printf '%s' \"$!\" > \"$1\"; wait", "environment-fixture", pidFile.path])
    let task = Task { try await RuntimeEnvironmentProcessRunner().run(source: source, baseEnvironment: ["PATH": "/usr/bin:/bin"], maxOutputBytes: 128) }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) { try await Task.sleep(nanoseconds: 10_000_000) }
    let pid = try String(contentsOf: pidFile, encoding: .utf8)
    task.cancel()
    do { _ = try await task.value; XCTFail("cancelled loader") } catch { XCTAssertTrue(error is CancellationError) }
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", pid, "-o", "stat="]
    let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
    try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    let state = (String(bytes: data, encoding: .utf8) ?? "encoding-failed").trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertTrue(state.isEmpty || state.hasPrefix("Z"), "owned descendant remains live")
  }

  func testChildInstallFailureDoesNotSwapSnapshot() async throws {
    let runner = EnvironmentRunnerStub([.success(Data("{\"TOKEN\":\"old\"}".utf8)), .success(Data("{\"TOKEN\":\"candidate\"}".utf8))])
    let store = RuntimeEnvironmentSnapshotStore(runner: runner)
    _ = try await store.prepare(scope: scope, configuration: configuration(), requiredNames: [], baseEnvironment: [:])
    do {
      _ = try await store.reload(scope: scope, configuration: configuration(), requiredNames: [], baseEnvironment: [:], install: { snapshot in
        XCTAssertEqual(snapshot.runtimeEnvironment()["TOKEN"], "candidate")
        throw RuntimeEnvironmentError.sourceFailed
      }); XCTFail("child ACK failed")
    } catch {}
    let current = try await store.capture(scope: scope)
    XCTAssertEqual(current.generation, 1); XCTAssertEqual(current.runtimeEnvironment()["TOKEN"], "old")
  }

  func testStrictOutputParsingAndEnv0Allowlist() async throws {
    for wire in ["{\"TOKEN\":\"a\",\"TOKEN\":\"b\"}", "{\"bad-key\":\"secret\"}", "{\"TOKEN\":1}", "{\"TOKEN\":\"bad\\u0000value\"}"] {
      XCTAssertThrowsError(try RuntimeEnvironmentOutput.decode(Data(wire.utf8), format: .json))
    }
    for wire in [Data("TOKEN=a\0TOKEN=b\0".utf8), Data("bad-key=x\0".utf8), Data("TOKEN=x".utf8), Data([0xff, 0])] {
      XCTAssertThrowsError(try RuntimeEnvironmentOutput.decode(wire, format: .env0))
    }
    let runner = EnvironmentRunnerStub([.success(Data("TOKEN=kept\0OTHER=discarded-canary\0".utf8))])
    let store = RuntimeEnvironmentSnapshotStore(runner: runner)
    let snapshot = try await store.prepare(scope: scope, configuration: configuration(.env0), requiredNames: [], baseEnvironment: [:])
    XCTAssertEqual(snapshot.runtimeEnvironment(), ["TOKEN": "kept"])
    let large = RuntimeEnvironmentSnapshotStore(runner: EnvironmentRunnerStub([.success(Data(repeating: 65, count: 65))]), maxOutputBytes: 64)
    do { _ = try await large.prepare(scope: scope, configuration: configuration(), requiredNames: [], baseEnvironment: [:]); XCTFail("oversize") } catch {
      XCTAssertEqual(error as? RuntimeEnvironmentError, .outputTooLarge) }
  }

  func testInheritedNonPortableEnvironmentNamesDoNotFailSources() async throws {
    let source = RuntimeEnvironmentCommandSource(id: "printf", names: ["TOKEN"], command: ["/usr/bin/printf", "%s", "{}"])
    let data = try await RuntimeEnvironmentProcessRunner().run(source: source,
      baseEnvironment: ["PATH": "/usr/bin:/bin", "BASH_FUNC_which%%": "() {  true\n}"], maxOutputBytes: 128)
    XCTAssertEqual(String(bytes: data, encoding: .utf8), "{}")
  }

  func testRealProcessTimeoutOutputBoundAndNonzeroErrorsAreSafe() async throws {
    let runner = RuntimeEnvironmentProcessRunner()
    struct FailureCase {
      var source: RuntimeEnvironmentCommandSource
      var limit: Int
      var expected: RuntimeEnvironmentError
    }
    let cases: [FailureCase] = [
      .init(source: .init(id: "timeout", names: ["TOKEN"], command: ["/bin/sleep", "5"], timeoutSeconds: 0.05), limit: 128, expected: .sourceTimeout),
      .init(source: .init(id: "large", names: ["TOKEN"], command: ["/usr/bin/printf", "%s", String(repeating: "canary", count: 100)]), limit: 32, expected: .outputTooLarge),
      .init(source: .init(id: "failure", names: ["TOKEN"], command: ["/usr/bin/false"]), limit: 128, expected: .sourceFailed)
    ]
    for item in cases {
      let source = item.source; let limit = item.limit; let expected = item.expected
      do { _ = try await runner.run(source: source, baseEnvironment: [:], maxOutputBytes: limit); XCTFail("expected failure") } catch {
      XCTAssertEqual(error as? RuntimeEnvironmentError, expected); XCTAssertFalse(String(describing: error).contains("canary"))
      }
    }
  }

  /// B8: a concurrent reload is a precondition failure with its own code and
  /// never overwrites the in-flight reload's status.
  func testConcurrentReloadReportsInProgressWithoutTouchingStatus() async throws {
    let runner = EnvironmentRunnerStub([.success(Data("{\"TOKEN\":\"slow\"}".utf8))], delay: 200_000_000)
    let store = RuntimeEnvironmentSnapshotStore(runner: runner)
    let scope = self.scope
    let config = configuration()
    let first = Task { try await store.reload(scope: scope, configuration: config, requiredNames: [], baseEnvironment: [:]) }
    var attempts = 0
    while await runner.count() < 1, attempts < 200 { attempts += 1; try await Task.sleep(nanoseconds: 2_000_000) }
    let before = await store.status(scope: scope)
    do {
      _ = try await store.reload(scope: scope, configuration: config, requiredNames: [], baseEnvironment: [:])
      XCTFail("second reload must report in-progress")
    } catch { XCTAssertEqual(error as? RuntimeEnvironmentError, .reloadInProgress) }
    let during = await store.status(scope: scope)
    XCTAssertEqual(during, before, "busy path must not write status")
    let finished = try await first.value
    XCTAssertEqual(finished.readiness, .ready)
    XCTAssertNil(finished.lastError)
    XCTAssertEqual(finished.generation, 1)
    let status = await store.status(scope: scope)
    XCTAssertEqual(status, finished)
    let calls = await runner.count(); XCTAssertEqual(calls, 1)
  }

  /// Descriptor-change rule: without a live child the previous entry is dropped
  /// on failure; with one (`retainPreviousOnFailure`) it is kept.
  func testChangedDescriptorFailureRetainsPreviousOnlyForLiveChild() async throws {
    let runner = EnvironmentRunnerStub([.success(Data("{\"TOKEN\":\"old\"}".utf8)), .failure(.sourceFailed)])
    let store = RuntimeEnvironmentSnapshotStore(runner: runner)
    _ = try await store.prepare(scope: scope, configuration: configuration(), requiredNames: [], baseEnvironment: [:])
    var changed = configuration(); changed.sources[0].command = ["/changed"]
    do {
      _ = try await store.reload(scope: scope, configuration: changed, requiredNames: [], baseEnvironment: [:], retainPreviousOnFailure: true)
      XCTFail("changed loader fails")
    } catch { XCTAssertEqual(error as? RuntimeEnvironmentError, .sourceFailed) }
    let kept = try await store.capture(scope: scope)
    XCTAssertEqual(kept.runtimeEnvironment()["TOKEN"], "old")
    let status = await store.status(scope: scope)
    XCTAssertEqual(status.readiness, .ready); XCTAssertEqual(status.generation, 1); XCTAssertEqual(status.lastError, .sourceFailed)
  }

  /// Eviction drops credentials and status, cancels nothing it does not own,
  /// leaves other profiles alone, and an in-flight reload publishes nothing.
  func testEvictDropsScopeAndInFlightReloadPublishesNothing() async throws {
    let runner = EnvironmentRunnerStub([
      .success(Data("{\"TOKEN\":\"one\"}".utf8)), .success(Data("{\"TOKEN\":\"other\"}".utf8)),
      .success(Data("{\"TOKEN\":\"late\"}".utf8))
    ])
    let store = RuntimeEnvironmentSnapshotStore(runner: runner)
    let other = RuntimeEnvironmentScope(profile: "work", instanceIdentity: "fixture")
    _ = try await store.prepare(scope: scope, configuration: configuration(), requiredNames: [], baseEnvironment: [:])
    _ = try await store.prepare(scope: other, configuration: configuration(), requiredNames: [], baseEnvironment: [:])
    await store.evict(profile: "default")
    do { _ = try await store.capture(scope: scope); XCTFail("evicted") } catch { XCTAssertEqual(error as? RuntimeEnvironmentError, .notPrepared) }
    let evictedStatus = await store.status(scope: scope)
    XCTAssertEqual(evictedStatus, RuntimeEnvironmentStatus())
    let untouched = try await store.capture(scope: other)
    XCTAssertEqual(untouched.runtimeEnvironment()["TOKEN"], "other")

    let scope = self.scope
    let config = configuration()
    let reload = Task {
      try await store.reload(scope: scope, configuration: config, requiredNames: [], baseEnvironment: [:], install: { _ in
        await store.evict(scope: scope)
      })
    }
    do { _ = try await reload.value; XCTFail("evicted during install") } catch {
      XCTAssertEqual(error as? RuntimeEnvironmentError, .notPrepared) }
    do { _ = try await store.capture(scope: scope); XCTFail("nothing published") } catch {}
    let after = await store.status(scope: scope)
    XCTAssertEqual(after, RuntimeEnvironmentStatus())
  }

  func testChannelWireTypesMatchChildEncodingAndNeverRenderValues() throws {
    // Byte layout the CLI child writes today (RielaCLI RuntimeEnvironmentAcknowledgement).
    let childLine = Data(#"{"type":"runtime-environment-ack","generation":3,"names":["A","B"],"accepted":true}"#.utf8)
    let ack = try XCTUnwrap(RuntimeEnvironmentChannelAcknowledgement.decodeLine(childLine))
    XCTAssertEqual(ack, RuntimeEnvironmentChannelAcknowledgement(generation: 3, names: ["A", "B"], accepted: true))
    let rejected = Data(#"{"type":"runtime-environment-ack","names":[],"accepted":false,"error":"environment_channel_invalid"}"#.utf8)
    XCTAssertEqual(RuntimeEnvironmentChannelAcknowledgement.decodeLine(rejected)?.error, "environment_channel_invalid")
    XCTAssertNil(RuntimeEnvironmentChannelAcknowledgement.decodeLine(Data(#"{"type":"log","generation":1,"names":[],"accepted":true}"#.utf8)))
    XCTAssertNil(RuntimeEnvironmentChannelAcknowledgement.decodeLine(Data("not json".utf8)))
    let canary = "frame-canary-" + UUID().uuidString
    let frame = RuntimeEnvironmentChannelFrame(generation: 4, managedNames: ["TOKEN"], values: ["TOKEN": canary])
    let line = try frame.encodedLine()
    XCTAssertEqual(line.last, 10)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
    XCTAssertEqual(Set(object.keys), ["generation", "managedNames", "values"])
    XCTAssertFalse(String(describing: frame).contains(canary))
    XCTAssertFalse(String(reflecting: frame).contains(canary))
    let huge = RuntimeEnvironmentChannelFrame(generation: 5, managedNames: ["TOKEN"],
      values: ["TOKEN": String(repeating: "x", count: RuntimeEnvironmentChannelWire.maxFrameBytes)])
    XCTAssertThrowsError(try huge.encodedLine()) { XCTAssertEqual($0 as? RuntimeEnvironmentError, .outputTooLarge) }
  }

  func testManagedChildDiagnosticsKeepOnlySafeCodes() {
    XCTAssertEqual(managedChildDiagnosticCode(Data("environment_required_missing".utf8)), "environment_required_missing")
    XCTAssertEqual(managedChildDiagnosticCode(Data("error: environment_channel_closed\r".utf8)), "environment_channel_closed")
    for line in ["private-canary-never-retained", "TOKEN=secret", "environment_", "my_password_value",
                 "environment_required_missing: TOKEN", "Environment_required_missing", "environment_9"] {
      XCTAssertNil(managedChildDiagnosticCode(Data(line.utf8)), line)
    }
  }
}
