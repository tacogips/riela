import Foundation
import RielaCore

func checkSnapshotWork(_ context: AdapterExecutionContext) throws {
  try Task.checkCancellation()
  if let deadline = context.deadline, deadline <= Date() {
    throw AdapterExecutionError(.invalidInput, "snapshot work deadline reached")
  }
}

func preflightSnapshotFiles(_ database: URL) throws {
  for suffix in ["", "-wal", "-shm", "-journal"] {
    let file = database.path + suffix
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: file)) != nil {
      throw AdapterExecutionError(.invalidInput, "unsafe snapshot metadata path")
    }
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: file)
      guard attributes[.type] as? FileAttributeType == .typeRegular,
        (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
        throw AdapterExecutionError(.invalidInput, "unsafe snapshot metadata path")
      }
    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
      continue
    }
  }
}

final class SnapshotScanEnumerationFailure: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func mark() { lock.lock(); defer { lock.unlock() }; value = true }
  var failed: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

func snapshotWorkResult(_ operation: () throws -> AdapterExecutionOutput) throws -> AdapterExecutionOutput {
  do { return try operation()
  } catch is CancellationError { throw CancellationError()
  } catch let error as AdapterExecutionError { throw error
  } catch { throw AdapterExecutionError(.invalidInput, "snapshot metadata operation failed") }
}

func snapshotDirectoryExists(_ directory: URL) throws -> Bool {
  do {
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
      throw AdapterExecutionError(.invalidInput, "invalid snapshot metadata directory")
    }
    return true
  } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
    return false
  }
}

func snapshotDatabaseIdentity(_ database: URL) throws -> String? {
  do {
    let attributes = try FileManager.default.attributesOfItem(atPath: database.path)
    guard let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber else {
      throw AdapterExecutionError(.invalidInput, "invalid snapshot metadata identity")
    }
    return device.stringValue + ":" + inode.stringValue
  } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
    return nil
  }
}
