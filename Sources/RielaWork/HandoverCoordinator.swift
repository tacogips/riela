import Foundation
import RielaCore

public struct HandoverSealRequest: Sendable {
  public var builderInput: HandoverPacketBuilderInput
  public var publisher: (any DeliverablePublisher)?
  public var ownerAlive: Bool
  public var sinks: [any HandoverSink]
  public var decisionId: DecisionID
  public var decisionProducer: DecisionProducer
  public var predecessorOutcome: AttemptOutcome
  public var expectedTaskVersion: Int

  public init(builderInput: HandoverPacketBuilderInput, publisher: (any DeliverablePublisher)? = nil,
              ownerAlive: Bool, sinks: [any HandoverSink] = [], decisionId: DecisionID,
              decisionProducer: DecisionProducer, predecessorOutcome: AttemptOutcome, expectedTaskVersion: Int) {
    self.builderInput = builderInput; self.publisher = publisher; self.ownerAlive = ownerAlive; self.sinks = sinks
    self.decisionId = decisionId; self.decisionProducer = decisionProducer
    self.predecessorOutcome = predecessorOutcome; self.expectedTaskVersion = expectedTaskVersion
  }
}

public struct HandoverCoordinator: Sendable {
  private let store: WorkStore
  private let builder: HandoverPacketBuilder
  public init(store: WorkStore, builder: HandoverPacketBuilder) { self.store = store; self.builder = builder }

  public func seal(_ request: HandoverSealRequest) async throws -> HandoverPacket {
    var input = request.builderInput
    if let publisher = request.publisher {
      input.deliverables += await publisher.publish(task: input.task, attempt: input.attempt,
                                                   snapshot: input.snapshot, ownerAlive: request.ownerAlive)
    }
    let packet = try builder.build(input)
    let decision = Decision(id: request.decisionId, taskId: input.task.id, attemptId: input.attempt.id,
      producer: request.decisionProducer, kind: .handover(input.reason), reason: input.reason.kindName,
      createdAt: input.now)
    let evidence = Evidence(id: EvidenceID("evidence-handover-\(input.handoverId.rawValue)"), taskId: input.task.id,
      attemptId: input.attempt.id, kind: .handover, producedBy: .runtime,
      payloadRef: .inline(["handoverId": .string(input.handoverId.rawValue), "digest": .string(packet.digest),
                           "reasonKind": .string(input.reason.kindName)]), createdAt: input.now)
    _ = try store.sealHandoverRecords(packet: packet, decision: decision, evidence: [evidence],
      predecessorOutcome: request.predecessorOutcome, snapshot: input.snapshot,
      expectedTaskVersion: request.expectedTaskVersion, now: input.now)
    let storeRef = HandoverSinkRef(kind: .store, locator: "\(input.hostId)/\(input.task.id.rawValue)/\(packet.id.rawValue)",
                                   digest: packet.digest, writtenAt: input.now)
    var refs = [storeRef]
    let bytes = try JSONCanonical.encode(packet)
    for (index, sink) in request.sinks.enumerated() {
      do {
        refs.append(try await sink.write(packet, bytes: bytes, brief: packet.brief))
      } catch {
        let publication = Evidence(id: EvidenceID("evidence-publication-\(packet.id.rawValue)-\(index)"),
          taskId: input.task.id, attemptId: input.attempt.id, kind: .publication, producedBy: .runtime,
          payloadRef: .inline(["sink": .string(sink.kind.rawValue), "error": .string(String(describing: error))]), createdAt: input.now)
        try store.saveEvidence(publication)
      }
    }
    try store.recordSinkRefs(handoverId: packet.id, refs: refs)
    var returned = packet
    returned.sinks = refs
    return returned
  }
}
