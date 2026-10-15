import Foundation
import RielaCore

/// The same declared shares are used by host-service capability checks. Native
/// backends share paths at their physical host location; containers may also
/// declare explicit remapped mounts in their container settings.
func builtinSandboxContainerSettings(_ sandbox: WorkflowExecutionSandbox) throws -> WorkflowAddonContainerExecution {
  try sandbox.validate()
  var settings = sandbox.container ?? .init()
  settings.networkPolicy = sandbox.networkPolicy
  var mounts = Dictionary(uniqueKeysWithValues: settings.mounts.map { ($0.target, $0) })
  let reads = sandbox.readPaths + sandbox.credentialPaths
  for path in reads where mounts[path] == nil {
    mounts[path] = .init(source: path, target: path, readOnly: true)
  }
  for path in sandbox.writePaths {
    mounts[path] = .init(source: path, target: path, readOnly: false)
  }
  settings.mounts = mounts.values.sorted { $0.target < $1.target }
  try settings.validate()
  return settings
}
