import RielaCore
import XCTest

final class AskCitationsTests: XCTestCase {
  func testReturnsOnlyKnownMarkersInAnswerOrder() {
    let session = AskRef(kind: .session, id: "s1")
    let bot = AskRef(kind: .bot, id: "b1")
    let workflow = AskRef(kind: .workflow, id: "w1")
    let routine = AskRef(kind: .routine, id: "r1")
    let step = AskRef(kind: .step, id: "read", sessionId: "s1")
    let text = "[[session:s1]] [[session:s2]] [[step:s2/read]] [[step:s1/read]] [[bot:b1]] [[workflow:w1]] [[routine:r1]] [[session:s1]]"
    XCTAssertEqual(
      AskCitations.extract(text: text, knownRefs: [routine, workflow, bot, step, session, session]),
      [session, step, bot, workflow, routine]
    )
  }

  func testMarkerKindAndStepSessionMustMatch() {
    let refs = [AskRef(kind: .step, id: "s1", sessionId: "other"), AskRef(kind: .bot, id: "s1")]
    let text = "[[session:s1]] [[step:s1/s1]] [[step:s1]] [[bot:s1]"
    XCTAssertTrue(AskCitations.extract(text: text, knownRefs: refs).isEmpty)
  }
}
