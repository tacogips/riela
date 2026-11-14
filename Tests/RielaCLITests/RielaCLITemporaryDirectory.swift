import Foundation

func makeRielaCLITestTemporaryDirectory(_ name: String) throws -> URL {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/riela-cli-tests", isDirectory: true)
  let directory = root.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}
