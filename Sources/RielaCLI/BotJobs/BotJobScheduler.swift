import Foundation
import RielaCore
import RielaObservability

actor BotJobScheduler {
  private let evaluate: @Sendable (Date) async -> Void
  private var lastTick: Date?
  private var active: Task<Void, Never>?
  private var closed = false

  init(evaluate: @escaping @Sendable (Date) async -> Void) {
    self.evaluate = evaluate
  }

  func tickIfDue(now: Date) {
    guard !closed, active == nil, lastTick.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
    lastTick = now
    active = Task {
      await evaluate(now)
      active = nil
    }
  }

  func shutdown() async {
    closed = true
    active?.cancel()
    await active?.value
  }

  static func evaluate(in service: BotsService, admissionGate: EventAdmissionGate? = nil) async {
    do {
      let bots = try service.store.list()
      for bot in bots {
        for job in BotJobKind.allCases where job.schedule(for: bot) != .off {
          guard !Task.isCancelled else { return }
          do {
            try await admissionGate?.admit()
          } catch {
            return
          }
          do {
            _ = try await service.runJob(botId: bot.botId, job: job, force: false)
          } catch where !Task.isCancelled {
            warn(error)
          } catch {
            // Shutdown cancels the active job and waits for its ledger settlement.
          }
          await admissionGate?.release()
        }
      }
    } catch {
      warn(error)
    }
  }

  private static func warn(_ error: any Error) {
    let code = (error as? BotStoreError)?.code ?? "bot_job_scheduler_failed"
    RielaStandardStreams.writeError("riela bot job: \(code)\n")
  }
}
