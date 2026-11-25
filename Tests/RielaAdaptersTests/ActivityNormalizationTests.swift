import ACP
import Foundation
import Testing
@testable import RielaAdapters
import RielaCore

@Suite struct ActivityNormalizationTests {
  @Test(arguments: ACPTranscriptFixtures.v1) func v1(_ fixture: ACPTranscriptFixtures.Update) throws {
    let update = try fixture.v1()
    #expect([GatewayActivityMapping.update(from: update)] == fixture.activity)
  }

  @Test(arguments: ACPTranscriptFixtures.v2) func v2(_ fixture: ACPTranscriptFixtures.Update) throws {
    let update = try fixture.v2()
    let activity = [GatewayActivityMapping.update(from: update)] + [GatewayActivityMapping.mode(from: update)].compactMap { $0 }
    #expect(activity == fixture.activity)
  }

  @Test func stopReadsOnlyStructuredLimitSignals() throws {
    let date = Date(timeIntervalSince1970: 1_767_225_600)
    let rateLimit: ACPJSONValue = .object(["limit": .object(["kind": .string("rate_limit"), "resetAt": .string("2026-01-01T00:00:00Z")])])
    #expect(GatewayActivityMapping.stop(stopReason: "error", meta: rateLimit, error: nil)
      == .stop(stopReason: "error", limited: true, limitedResetAt: date))
    let error = ACPError(code: -32_000, message: "quota", data: .object(["limit": .object(["kind": .string("usage_limit")])]))
    #expect(GatewayActivityMapping.stop(stopReason: "error", meta: nil, error: error)
      == .stop(stopReason: "error", limited: true, limitedResetAt: nil))
    #expect(GatewayActivityMapping.stop(stopReason: "error", meta: nil, error: .internalError("hit rate limit"))
      == .stop(stopReason: "error", limited: false, limitedResetAt: nil))
  }

  @Test(arguments: [#"{"stopReason":"future","_meta":{"model":"real"}}"#, #"{"_meta":{"model":"real"}}"#])
  func v1OpenResponsePreservesUnknownStopMetadata(_ wire: String) throws {
    let response = try JSONDecoder().decode(GatewayOpenV1PromptResponse.self, from: Data(wire.utf8))
    let reason = response.stopReason ?? "unknown"
    do {
      _ = try gatewayStopReason(response.stopReason, meta: response.meta)
      Issue.record("expected provider failure")
    } catch let failure as GatewayTurnFailure {
      #expect(failure.error.code == .providerError)
      #expect(failure.reason == reason)
      #expect(GatewayActivityMapping.reportedModel(meta: failure.meta) == .reportedModel("real"))
    }
  }

  @Test func v2ClearAndUnchangedMessageAreDistinct() {
    let clear = ACPV2SessionUpdate.agentMessage(.init(messageId: "message", content: .clear))
    #expect(GatewayActivityMapping.update(from: clear) == .message(messageId: "message", text: "", replace: true))
    let unchanged = ACPV2SessionUpdate.agentMessage(.init(messageId: "message", content: .unchanged))
    #expect(GatewayActivityMapping.update(from: unchanged) == .other(updateKind: "agent_message"))
  }
}
