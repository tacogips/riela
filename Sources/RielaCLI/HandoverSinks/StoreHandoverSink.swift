import Foundation
import RielaCore
import RielaWork

struct StoreHandoverSink: HandoverSink {
  let store: WorkStore
  let hostId: String
  let kind: HandoverSinkKind = .store

  init(store: WorkStore, hostId: String) {
    self.store = store
    self.hostId = hostId
  }

  func write(_ packet: HandoverPacket, bytes: Data, brief: String) async throws -> HandoverSinkRef {
    HandoverSinkRef(
      kind: kind,
      locator: "\(hostId)/\(packet.taskId.rawValue)/\(packet.id.rawValue)",
      digest: packet.digest,
      writtenAt: Date()
    )
  }

  func read(_ ref: HandoverSinkRef) async throws -> Data {
    guard ref.kind == kind,
          let handoverId = ref.locator.split(separator: "/", omittingEmptySubsequences: false).last,
          !handoverId.isEmpty,
          let packet = try store.loadHandover(id: HandoverID(String(handoverId))) else {
      throw HandoverSinkError.notFound(ref.locator)
    }
    return try JSONCanonical.encode(packet)
  }
}
