import Foundation
import XCTest
@testable import RielaCore

final class DistributedArtifactTests: XCTestCase {
  func testCollectionIsBoundedAndRejectsTraversalSymlinksAndSpecialFiles() throws {
    let root = try fixtureRoot()
    try Data("report".utf8).write(to: root.appendingPathComponent("report"))
    let artifacts = try DistributedArtifact.collect(paths: ["report"], root: root)
    XCTAssertEqual(artifacts.first?.data, Data("report".utf8))
    for path in ["", "../report", "/report", "a/../report", "a//report", "a/./report", "a\\report"] {
      XCTAssertThrowsError(try DistributedArtifact.collect(paths: [path], root: root))
    }
    XCTAssertThrowsError(try DistributedArtifact.collect(paths: ["report", "report"], root: root))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("report"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dir-link"), withDestinationURL: root)
    XCTAssertThrowsError(try DistributedArtifact.collect(paths: ["link"], root: root))
    XCTAssertThrowsError(try DistributedArtifact.collect(paths: ["dir-link/report"], root: root))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("directory"), withIntermediateDirectories: true)
    XCTAssertThrowsError(try DistributedArtifact.collect(paths: ["directory"], root: root))
    XCTAssertThrowsError(try DistributedArtifact.collect(paths: ["missing"], root: root))
    try Data(repeating: 0, count: DistributedArtifact.maximumTotalBytes).write(to: root.appendingPathComponent("large"))
    XCTAssertEqual(try DistributedArtifact.collect(paths: ["large"], root: root).first?.data.count, DistributedArtifact.maximumTotalBytes)
    XCTAssertThrowsError(try DistributedArtifact.collect(paths: ["large", "report"], root: root))
  }

  func testManifestRejectsCorruptionUnexpectedFilesAndOmissions() throws {
    let artifact = DistributedArtifact(path: "report", data: Data("report".utf8))
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(artifact)) as? [String: Any])
    json["sha256"] = String(repeating: "0", count: 64)
    let corrupt = try JSONDecoder().decode(DistributedArtifact.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertThrowsError(try DistributedArtifact.validate([corrupt], expectedPaths: ["report"]))
    XCTAssertThrowsError(try DistributedArtifact.validate([artifact], expectedPaths: []))
    XCTAssertThrowsError(try DistributedArtifact.validate([], expectedPaths: ["report"]))
    XCTAssertThrowsError(try DistributedArtifact.validate([artifact, artifact], expectedPaths: ["report"]))
  }

  func testAcknowledgedArtifactsSurviveRestartAndRestoreMissingFiles() async throws {
    let root = try fixtureRoot()
    let store = root.appendingPathComponent("jobs.json")
    let controller = try DistributedJobController(fileURL: store)
    let worker = try await controller.register(workerId: "worker", groups: [], capacity: 1)
    _ = try await controller.enqueue(id: "job", target: .init(), payload: try requestPayload())
    let job = try await controller.claim(worker: worker, now: Date(), leaseDuration: 30)
    let token = try XCTUnwrap(job?.lease?.token)
    let artifact = DistributedArtifact(path: "report", data: Data("remote output".utf8))
    let result = DistributedJobResult(outcome: .succeeded, payload: [:], artifacts: [artifact])
    _ = try await controller.complete(jobId: "job", worker: worker, token: token, result: result, now: Date())
    _ = try await controller.complete(jobId: "job", worker: worker, token: token, result: result, now: Date())
    let restarted = try DistributedJobController(fileURL: store)
    let locations = try await restarted.artifacts(jobId: "job")
    let location = try XCTUnwrap(locations.first)
    XCTAssertEqual(try Data(contentsOf: location.url), artifact.data)
    XCTAssertEqual(location.sha256, artifact.sha256)
    let attributes = try FileManager.default.attributesOfItem(atPath: location.url.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    try FileManager.default.removeItem(at: location.url)
    _ = try await restarted.artifacts(jobId: "job")
    XCTAssertEqual(try Data(contentsOf: location.url), artifact.data)
  }

  func testCancelledAndUnrequestedArtifactsNeverMaterialize() async throws {
    let root = try fixtureRoot()
    let store = root.appendingPathComponent("jobs.json")
    let controller = try DistributedJobController(fileURL: store)
    let worker = try await controller.register(workerId: "worker", groups: [], capacity: 1)
    _ = try await controller.enqueue(id: "job", target: .init(), payload: try requestPayload())
    let job = try await controller.claim(worker: worker, now: Date(), leaseDuration: 30)
    let token = try XCTUnwrap(job?.lease?.token)
    let unsolicited = DistributedJobResult(outcome: .succeeded, payload: [:], artifacts: [.init(path: "other", data: Data())])
    do {
      _ = try await controller.complete(jobId: "job", worker: worker, token: token, result: unsolicited, now: Date())
      XCTFail("Unexpected file accepted")
    } catch let error as AdapterExecutionError { XCTAssertEqual(error.code, .invalidOutput) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathExtension("artifacts").path))
    try await controller.cancel(jobId: "job")
    let valid = DistributedJobResult(outcome: .succeeded, payload: [:], artifacts: [.init(path: "report", data: Data())])
    do {
      _ = try await controller.complete(jobId: "job", worker: worker, token: token, result: valid, now: Date())
      XCTFail("Cancelled artifact accepted")
    } catch { XCTAssertEqual(error as? DistributedWorkerError, .staleLease) }
    let locations = try await controller.artifacts(jobId: "job")
    XCTAssertTrue(locations.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathExtension("artifacts").path))
  }

  func testPlacementExportSchema() {
    for exports: Any in [["report"], [], ["../report"], ["report", "report"], "report", NSNull()] {
      var diagnostics: [WorkflowValidationDiagnostic] = []
      validateDistributedPlacement(["workspace": "project", "target": [:], "exports": exports], path: "placement", diagnostics: &diagnostics)
      let valid = (exports as? [String]).map { $0 == ["report"] || $0.isEmpty } ?? false
      XCTAssertEqual(diagnostics.isEmpty, valid)
    }
  }

  private func requestPayload() throws -> JSONObject {
    let request = DistributedNodeRequest(
      invocation: .adapter(.init(node: .init(id: "node", model: "local"), promptText: "test")),
      workspace: "project", timeoutSeconds: 30, exports: ["report"]
    )
    return try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(request))
  }

  private func fixtureRoot() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/distributed-workers/artifact-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
}
