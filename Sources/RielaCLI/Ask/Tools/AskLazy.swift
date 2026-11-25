import Foundation
import RielaCore

/// A value built on first use and then shared. Construction of an Ask host must not touch the
/// runtime store, so anything that creates files (the retain key) sits behind one of these.
final class AskLazy<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private let make: @Sendable () throws(AskError) -> Value
  private var resolved: Result<Value, AskError>?

  init(_ make: @escaping @Sendable () throws(AskError) -> Value) {
    self.make = make
  }

  func get() throws(AskError) -> Value {
    lock.lock()
    defer { lock.unlock() }
    if let resolved { return try resolved.get() }
    let result: Result<Value, AskError>
    do {
      result = .success(try make())
    } catch {
      result = .failure(error)
    }
    resolved = result
    return try result.get()
  }

  func map<Mapped: Sendable>(_ transform: @escaping @Sendable (Value) -> Mapped) -> AskLazy<Mapped> {
    AskLazy<Mapped> { () throws(AskError) -> Mapped in transform(try self.get()) }
  }
}
