import Foundation
import RielaCore

extension WorkflowRunCommand {
  func persistSupervisionRecord(
    sessionId: String,
    storeRoot: String,
    workflowName: String,
    supervision: JSONObject
  ) throws {
    let directory = URL(fileURLWithPath: canonicalRuntimeStoreRoot(sessionStoreRoot: storeRoot), isDirectory: true)
      .appendingPathComponent(sessionId, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var record = supervision
    record["sessionId"] = .string(sessionId)
    record["workflowName"] = .string(workflowName)
    try jsonString(record).write(to: directory.appendingPathComponent("supervision-record.json"), atomically: true, encoding: .utf8)
  }
}
