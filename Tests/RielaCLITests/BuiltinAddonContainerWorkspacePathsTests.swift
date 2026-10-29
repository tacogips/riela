import Foundation
import RielaCore
import XCTest

@testable import RielaCLI

final class BuiltinAddonContainerWorkspacePathsTests: XCTestCase {
  func testMapsWorkspacePathsIntoGuestAndBackToHost() {
    let hostRoot = URL(fileURLWithPath: "/private/tmp/run", isDirectory: true)
    let input = WorkflowAddonExecutionInput(
      workflowId: "video", stepId: "frames", nodeId: "frames",
      addon: .init(name: "riela/video-frames", version: "1", config: ["options": .object([
        "path": .string("/private/tmp/run/video.mp4"),
        "segments": .array([.object(["path": .string("/private/tmp/run/segment.mp3")])])
      ])]),
      resolvedInputPayload: ["mediaDownload": .object(["path": .string("/private/tmp/run/video.mp4")])])

    let guestInput = BuiltinAddonContainerWorkspacePaths.mapInput(input, from: hostRoot)
    let guestOptions = Self.object(guestInput.addon.config?["options"])
    XCTAssertEqual(
      guestOptions?["path"], .string("/workspace/video.mp4"))
    XCTAssertEqual(
      Self.object(guestInput.resolvedInputPayload["mediaDownload"])?["path"], .string("/workspace/video.mp4"))
    XCTAssertEqual(
      Self.object(Self.array(guestOptions?["segments"])?.first)?["path"],
      .string("/workspace/segment.mp3"))

    let guestOutput = AdapterExecutionOutput(
      provider: "fixture", model: "riela/video-frames", promptText: "", completionPassed: true,
      payload: ["videoFrames": .object(["frames": .array([.object([
        "path": .string("/workspace/frame.jpg")
      ])]), "outputDir": .string("/workspace/.riela/artifacts/frames")])])
    let hostOutput = BuiltinAddonContainerWorkspacePaths.mapOutput(guestOutput, to: hostRoot)
    let hostFrames = Self.object(hostOutput.payload["videoFrames"])
    XCTAssertEqual(
      Self.object(Self.array(hostFrames?["frames"])?.first)?["path"],
      .string("/private/tmp/run/frame.jpg"))
    XCTAssertEqual(
      hostFrames?["outputDir"],
      .string("/private/tmp/run/.riela/artifacts/frames"))
  }

  func testDoesNotRewritePathsOutsideWorkspace() {
    let hostRoot = URL(fileURLWithPath: "/private/tmp/run", isDirectory: true)
    let input = WorkflowAddonExecutionInput(
      workflowId: "video", stepId: "audio", nodeId: "audio",
      addon: .init(name: "riela/audio-segments", config: ["options": .object([
        "path": .string("/private/tmp/run-elsewhere/video.mp4")
      ])]))

    let mapped = BuiltinAddonContainerWorkspacePaths.mapInput(input, from: hostRoot)
    XCTAssertEqual(
      Self.object(mapped.addon.config?["options"])?["path"], .string("/private/tmp/run-elsewhere/video.mp4"))
  }

  private static func object(_ value: JSONValue?) -> JSONObject? {
    guard case .object(let object) = value else { return nil }
    return object
  }

  private static func array(_ value: JSONValue?) -> [JSONValue]? {
    guard case .array(let array) = value else { return nil }
    return array
  }
}
