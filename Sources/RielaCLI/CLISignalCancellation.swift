import Dispatch
import Foundation

final class CLISignalCancellation: @unchecked Sendable {
  private let sources: [DispatchSourceSignal]

  init(signals: [Int32] = [SIGINT, SIGTERM], onSignal: @escaping @Sendable (Int32) -> Void) {
    self.sources = signals.map { signalNumber in
      signal(signalNumber, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
      source.setEventHandler {
        onSignal(signalNumber)
      }
      source.resume()
      return source
    }
  }

  func cancel() {
    for source in sources {
      source.cancel()
    }
  }
}
