import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Guest-writable state is distinct from host-only control records. Open every
/// component without following symlinks, including the guest-controlled HOME.
func prepareBuiltinAddonContainerState(at root: URL) throws {
  var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
  guard directory >= 0 else { throw stateError() }
  defer { close(directory) }
  for name in root.standardizedFileURL.pathComponents.dropFirst() + ["home"] {
    var child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if child < 0, errno == ENOENT {
      guard mkdirat(directory, name, 0o700) == 0 || errno == EEXIST else { throw stateError() }
      child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard child >= 0 else { throw stateError() }
    close(directory)
    directory = child
  }
}

private func stateError() -> AdapterExecutionError {
  .init(.policyBlocked, "container state directory must contain only accessible directories, without symlinks")
}
