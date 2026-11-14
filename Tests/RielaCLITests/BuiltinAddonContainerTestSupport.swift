import Foundation
import XCTest
@testable import RielaCLI

func builtinContainerTransportRoot(for workspace: URL, testCase: XCTestCase) -> URL {
  let root = workspace.deletingLastPathComponent()
    .appendingPathComponent(".container-controls", isDirectory: true)
    .appendingPathComponent(sha256(Data(workspace.path.utf8)), isDirectory: true)
  testCase.addTeardownBlock {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: BuiltinAddonContainerTransportStore.workerStateRoot(for: root))
  }
  return root
}
