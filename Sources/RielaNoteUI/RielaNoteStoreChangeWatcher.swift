import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class RielaNoteStoreChangeWatcher: @unchecked Sendable {
  private struct WatchTarget {
    var url: URL
    var fileDescriptor: Int32
    var source: DispatchSourceFileSystemObject
    var isDirectory: Bool
  }

  private let fileURLs: [URL]
  private let debounceInterval: TimeInterval
  private let queue = DispatchQueue(label: "RielaNoteStoreChangeWatcher")
  private let onChange: @MainActor @Sendable () async -> Void
  private var targets: [String: WatchTarget] = [:]
  private var debounceWorkItem: DispatchWorkItem?

  public init(
    fileURLs: [URL],
    debounceInterval: TimeInterval = 0.25,
    onChange: @escaping @MainActor @Sendable () async -> Void
  ) {
    self.fileURLs = fileURLs
    self.debounceInterval = debounceInterval
    self.onChange = onChange
  }

  deinit {
    stop()
  }

  @discardableResult
  public func start() -> Bool {
    queue.sync {
      stopLocked()
      guard !fileURLs.isEmpty else {
        return false
      }
      let parentDirectories = Set(fileURLs.map { $0.deletingLastPathComponent() })
      for directoryURL in parentDirectories {
        installWatcherLocked(url: directoryURL, isDirectory: true)
      }
      installExistingFileWatchersLocked()
      return !targets.isEmpty
    }
  }

  public func stop() {
    queue.sync {
      stopLocked()
    }
  }

  private func stopLocked() {
    debounceWorkItem?.cancel()
    debounceWorkItem = nil
    let currentTargets = targets.values
    targets = [:]
    for target in currentTargets {
      target.source.cancel()
    }
  }

  private func installExistingFileWatchersLocked() {
    for fileURL in fileURLs where FileManager.default.fileExists(atPath: fileURL.path) {
      installWatcherLocked(url: fileURL, isDirectory: false)
    }
  }

  private func installWatcherLocked(url: URL, isDirectory: Bool) {
    let key = watchKey(url: url, isDirectory: isDirectory)
    guard targets[key] == nil else {
      return
    }
    let fileDescriptor = openFileDescriptor(for: url)
    guard fileDescriptor >= 0 else {
      return
    }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: eventMask(isDirectory: isDirectory),
      queue: queue
    )
    source.setEventHandler { [weak self, weak source] in
      guard let source else {
        return
      }
      self?.handleEventLocked(url: url, isDirectory: isDirectory, flags: source.data)
    }
    source.setCancelHandler {
      close(fileDescriptor)
    }
    targets[key] = WatchTarget(url: url, fileDescriptor: fileDescriptor, source: source, isDirectory: isDirectory)
    source.resume()
  }

  private func handleEventLocked(
    url: URL,
    isDirectory: Bool,
    flags: DispatchSource.FileSystemEvent
  ) {
    let invalidatingEvents: DispatchSource.FileSystemEvent = [.delete, .rename, .revoke]
    if !isDirectory, !flags.isDisjoint(with: invalidatingEvents) {
      removeWatcherLocked(url: url, isDirectory: isDirectory)
    }
    if isDirectory {
      installExistingFileWatchersLocked()
    } else if !flags.isDisjoint(with: invalidatingEvents) {
      installExistingFileWatchersLocked()
    }
    scheduleChangeLocked()
  }

  private func removeWatcherLocked(url: URL, isDirectory: Bool) {
    let key = watchKey(url: url, isDirectory: isDirectory)
    guard let target = targets.removeValue(forKey: key) else {
      return
    }
    target.source.cancel()
  }

  private func scheduleChangeLocked() {
    debounceWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else {
        return
      }
      Task { @MainActor in
        await self.onChange()
      }
    }
    debounceWorkItem = workItem
    queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
  }

  private func eventMask(isDirectory: Bool) -> DispatchSource.FileSystemEvent {
    if isDirectory {
      return [.write, .delete, .rename, .revoke]
    }
    return [.write, .extend, .attrib, .delete, .rename, .revoke]
  }

  private func watchKey(url: URL, isDirectory: Bool) -> String {
    "\(isDirectory ? "directory" : "file"):\(url.path)"
  }
}

private func openFileDescriptor(for url: URL) -> Int32 {
  url.withUnsafeFileSystemRepresentation { path in
    guard let path else {
      return -1
    }
    #if canImport(Darwin)
    return open(path, O_EVTONLY)
    #else
    return open(path, O_RDONLY)
    #endif
  }
}
