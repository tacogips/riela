import Foundation
import RielaCore
@testable import RielaAppSupport
import XCTest

private actor EnvironmentRunnerStub: RuntimeEnvironmentCommandRunning {
  var outputs: [Result<Data, RuntimeEnvironmentError>]
  var calls = 0
  init(_ outputs: [Result<Data, RuntimeEnvironmentError>]) { self.outputs = outputs }
  func run(source: RuntimeEnvironmentCommandSource, baseEnvironment: [String: String], maxOutputBytes: Int) async throws -> Data {
    calls += 1
    return try outputs.removeFirst().get()
  }
  func count() -> Int { calls }
}

final class RuntimeEnvironmentSnapshotStoreTests: XCTestCase {
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
    let first = try await store.prepare(scope: scope, configuration: configuration(), requiredNames: [], baseEnvironment: ["HOME":"/fixture"])
    let cached = try await store.prepare(scope: scope, configuration: configuration(), requiredNames: [], baseEnvironment: [:])
    XCTAssertEqual(first.generation, cached.generation)
    let calls = await runner.count(); XCTAssertEqual(calls, 1)
    XCTAssertEqual(first.runtimeEnvironment()["TOKEN"], canary)
    do { _ = try await store.reload(scope: scope, configuration: configuration(), requiredNames: [], baseEnvironment: [:]); XCTFail("reload must fail") }
    catch { XCTAssertEqual(error as? RuntimeEnvironmentError, .sourceFailed) }
    let retained = try await store.capture(scope: scope); XCTAssertEqual(retained.runtimeEnvironment()["TOKEN"], canary)
    let status = await store.status(scope: scope); XCTAssertEqual(status.readiness, .ready); XCTAssertEqual(status.lastError, .sourceFailed)
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(status), as: UTF8.self).contains(canary))
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
    do { _ = try await store.prepare(scope: scope, configuration: configuration(), requiredNames: [], baseEnvironment: [:]); XCTFail("missing") }
    catch { XCTAssertEqual(error as? RuntimeEnvironmentError, .requiredMissing) }
    let missing = await store.status(scope: scope); XCTAssertEqual(missing.missingNames, ["TOKEN"])
    do { _ = try await store.capture(scope: scope); XCTFail("initial failure must block") } catch {}
    _ = try await store.prepare(scope: scope, configuration: configuration(), requiredNames: [], baseEnvironment: [:])
    var changed = configuration(); changed.sources[0].command = ["/changed"]
    do { _ = try await store.prepare(scope: scope, configuration: changed, requiredNames: [], baseEnvironment: [:]); XCTFail("changed source fails") } catch {}
    do { _ = try await store.capture(scope: scope); XCTFail("old descriptor must not remain usable") } catch {}
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
    XCTAssertEqual(snapshot.runtimeEnvironment(), ["TOKEN":"kept"])
    let large = RuntimeEnvironmentSnapshotStore(runner: EnvironmentRunnerStub([.success(Data(repeating: 65, count: 65))]), maxOutputBytes: 64)
    do { _ = try await large.prepare(scope: scope, configuration: configuration(), requiredNames: [], baseEnvironment: [:]); XCTFail("oversize") }
    catch { XCTAssertEqual(error as? RuntimeEnvironmentError, .outputTooLarge) }
  }

  func testRealProcessTimeoutOutputBoundAndNonzeroErrorsAreSafe() async throws {
    let runner = RuntimeEnvironmentProcessRunner()
    let cases: [(RuntimeEnvironmentCommandSource, Int, RuntimeEnvironmentError)] = [
      (.init(id: "timeout", names: ["TOKEN"], command: ["/bin/sleep", "5"], timeoutSeconds: 0.05), 128, .sourceTimeout),
      (.init(id: "large", names: ["TOKEN"], command: ["/usr/bin/printf", "%s", String(repeating: "canary", count: 100)]), 32, .outputTooLarge),
      (.init(id: "failure", names: ["TOKEN"], command: ["/usr/bin/false"]), 128, .sourceFailed)
    ]
    for (source, limit, expected) in cases {
      do { _ = try await runner.run(source: source, baseEnvironment: [:], maxOutputBytes: limit); XCTFail("expected failure") }
      catch { XCTAssertEqual(error as? RuntimeEnvironmentError, expected); XCTAssertFalse(String(describing: error).contains("canary")) }
    }
  }
}
