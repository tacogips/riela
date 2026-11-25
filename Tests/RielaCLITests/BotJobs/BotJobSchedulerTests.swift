import Foundation
import XCTest
@testable import RielaCLI

final class BotJobSchedulerTests: XCTestCase {
  func testTicksThrottleEvaluationToOncePerMinute() async {
    let probe = BotJobEvaluationProbe()
    let scheduler = BotJobScheduler { await probe.record($0) }
    let start = Date(timeIntervalSince1970: 100)
    let tooSoon = start.addingTimeInterval(10)
    let next = start.addingTimeInterval(61)

    await tickUntilRecorded(start, by: scheduler, probe: probe)
    // A tick only starts the task. Let that task release the actor before
    // advancing the injected clock past the throttling boundary.
    for _ in 0..<20 {
      await scheduler.tickIfDue(now: tooSoon)
      try? await Task.sleep(for: .milliseconds(1))
    }
    await tickUntilRecorded(next, by: scheduler, probe: probe)
    await scheduler.shutdown()

    let evaluations = await probe.evaluations
    XCTAssertEqual(evaluations, [start, next])
  }

  func testTickAfterMinuteDoesNotOverlapAnActiveEvaluation() async {
    let probe = BotJobEvaluationProbe()
    let start = Date(timeIntervalSince1970: 100)
    let later = start.addingTimeInterval(61)
    let afterRelease = start.addingTimeInterval(62)
    let (releaseSignal, release) = AsyncStream<Void>.makeStream()
    let scheduler = BotJobScheduler { date in
      await probe.record(date)
      if date == start {
        for await _ in releaseSignal { break }
      }
    }

    await tickUntilRecorded(start, by: scheduler, probe: probe)
    await scheduler.tickIfDue(now: later)
    release.finish()
    await tickUntilRecorded(afterRelease, by: scheduler, probe: probe)
    await scheduler.shutdown()

    let evaluations = await probe.evaluations
    XCTAssertEqual(evaluations, [start, afterRelease])
  }

  private func tickUntilRecorded(_ date: Date, by scheduler: BotJobScheduler, probe: BotJobEvaluationProbe) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
      await scheduler.tickIfDue(now: date)
      if await probe.evaluations.contains(date) { return }
      try? await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("No job evaluation for injected time \(date)")
  }
}

private actor BotJobEvaluationProbe {
  private(set) var evaluations: [Date] = []

  func record(_ date: Date) {
    evaluations.append(date)
  }
}
