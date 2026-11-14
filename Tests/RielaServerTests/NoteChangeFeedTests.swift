import Foundation
import RielaCore
import RielaNote
import XCTest
@testable import RielaServer

final class NoteChangeFeedTests: XCTestCase {
  func testRevisionIncreasesMonotonicallyWithEachPublish() async {
    let feed = NoteChangeFeed()
    await XCTAssertEqualAsync(await feed.currentRevision, 0)

    await feed.publish(NoteChangeEvent(kind: NoteChangeEventKind.notebookCreated, notebookId: "nb-1"))
    await XCTAssertEqualAsync(await feed.currentRevision, 1)

    await feed.publish(NoteChangeEvent(kind: NoteChangeEventKind.notebookProgress, notebookId: "nb-1"))
    await feed.publish(NoteChangeEvent(kind: NoteChangeEventKind.statusSets))
    await XCTAssertEqualAsync(await feed.currentRevision, 3)
  }

  func testPollReturnsImmediatelyWithUnseenEvents() async {
    let feed = NoteChangeFeed()
    await feed.publish(NoteChangeEvent(kind: NoteChangeEventKind.notebookCreated, notebookId: "nb-1"))
    await feed.publish(NoteChangeEvent(
      kind: NoteChangeEventKind.notebookProgress,
      notebookId: "nb-1",
      tagNames: ["proj/alpha"]
    ))

    let polled = await feed.poll(since: 1, timeoutNanoseconds: 30_000_000_000)
    XCTAssertEqual(polled.revision, 2)
    XCTAssertEqual(polled.events.map(\.kind), [NoteChangeEventKind.notebookProgress])
    XCTAssertEqual(polled.events.first?.tagNames, ["proj/alpha"])
  }

  func testPollWithStaleSinceReturnsCurrentRevisionWithoutEvents() async {
    let feed = NoteChangeFeed()
    for index in 0..<(NoteChangeFeed.bufferCapacity + 10) {
      await feed.publish(NoteChangeEvent(
        kind: NoteChangeEventKind.notebookProgress,
        notebookId: "nb-\(index)"
      ))
    }

    // Revision 1 has fallen out of the ring buffer, so the window can no longer
    // describe the gap and the poller is told to refresh wholesale.
    let polled = await feed.poll(since: 1, timeoutNanoseconds: 30_000_000_000)
    XCTAssertEqual(polled.revision, UInt64(NoteChangeFeed.bufferCapacity + 10))
    XCTAssertTrue(polled.events.isEmpty)
  }

  func testPollAheadOfTheFeedReturnsImmediatelySoARestartedCursorResyncs() async {
    let feed = NoteChangeFeed()
    await feed.publish(NoteChangeEvent(kind: NoteChangeEventKind.statusSets))

    let polled = await feed.poll(since: 99, timeoutNanoseconds: 30_000_000_000)
    XCTAssertEqual(polled.revision, 1)
    XCTAssertTrue(polled.events.isEmpty)
  }

  func testWaitingPollIsWokenByAPublish() async throws {
    let feed = NoteChangeFeed()
    let poll = Task {
      await feed.poll(since: 0, timeoutNanoseconds: 30_000_000_000)
    }
    // Let the poll reach its suspension point before publishing.
    try await Task.sleep(nanoseconds: 50_000_000)
    await feed.publish(NoteChangeEvent(
      kind: NoteChangeEventKind.notebookProgress,
      notebookId: "nb-1",
      tagNames: ["proj/alpha"]
    ))

    let polled = await poll.value
    XCTAssertEqual(polled.revision, 1)
    XCTAssertEqual(polled.events.map(\.notebookId), ["nb-1"])
  }

  func testPollTimesOutWithTheUnchangedRevision() async {
    let feed = NoteChangeFeed()
    let startedAt = Date()
    let polled = await feed.poll(since: 0, timeoutNanoseconds: 100_000_000)
    XCTAssertEqual(polled.revision, 0)
    XCTAssertTrue(polled.events.isEmpty)
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
  }

  func testCancellingAPollResumesItWithoutLeakingTheWaiter() async throws {
    let feed = NoteChangeFeed()
    let poll = Task {
      await feed.poll(since: 0, timeoutNanoseconds: 30_000_000_000)
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    poll.cancel()

    let polled = await poll.value
    XCTAssertEqual(polled.revision, 0)

    // The feed is still usable and has no stranded waiter holding the actor.
    await feed.publish(NoteChangeEvent(kind: NoteChangeEventKind.statusSets))
    let next = await feed.poll(since: 0, timeoutNanoseconds: 30_000_000_000)
    XCTAssertEqual(next.revision, 1)
  }

  func testFeedObserverPublishesEventsPassedToNoteChangeObserving() async throws {
    let feed = NoteChangeFeed()
    let observer = NoteChangeFeedObserver(feed: feed)
    observer.noteStoreDidChange(NoteChangeEvent(
      kind: NoteChangeEventKind.notebookTags,
      notebookId: "nb-7",
      tagNames: ["proj/alpha"]
    ))

    let polled = await feed.poll(since: 0, timeoutNanoseconds: 5_000_000_000)
    XCTAssertEqual(polled.revision, 1)
    XCTAssertEqual(polled.events.first?.notebookId, "nb-7")
    XCTAssertEqual(polled.events.first?.kind, NoteChangeEventKind.notebookTags)
  }
}

private func XCTAssertEqualAsync<T: Equatable>(
  _ expression: @autoclosure () async -> T,
  _ expected: T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  let value = await expression()
  XCTAssertEqual(value, expected, file: file, line: line)
}
