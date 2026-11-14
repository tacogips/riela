import Foundation

public enum RuntimeOutputCandidateSource: Equatable, Sendable {
  case adapterOutput
  case inlineCandidate
  case candidatePath(URL)
}

public struct RuntimeOutputCandidate: Equatable, Sendable {
  public var source: RuntimeOutputCandidateSource
  public var payload: JSONObject
  public var completionPassed: Bool
  public var when: [String: Bool]
  public var routingDiagnostics: [String]
  public var handover: HandoverEnvelope?

  public init(
    source: RuntimeOutputCandidateSource,
    payload: JSONObject,
    completionPassed: Bool = true,
    when: [String: Bool] = ["always": true],
    routingDiagnostics: [String] = [],
    handover: HandoverEnvelope? = nil
  ) {
    self.source = source
    self.payload = payload
    self.completionPassed = completionPassed
    self.when = when
    self.routingDiagnostics = routingDiagnostics
    self.handover = handover
  }
}

public enum RuntimeOutputCandidateError: Error, Equatable, Sendable {
  case missingCandidatePath(String)
  case candidatePathOutsideStaging(String)
  case candidatePathDoesNotMatchReservation(String)
  case staleCandidatePath(String)
  case malformedCandidateJSON(String)
  case nonObjectCandidate(String)
}

public protocol CandidatePathReading: Sendable {
  func readCandidate(
    from path: URL,
    stagingDirectory: URL,
    attemptStartedAt: Date,
    requiresObjectPayload: Bool,
    routingReconciler: OutputContractRoutingReconciler?
  ) async throws -> RuntimeOutputCandidate
}

public struct DefaultCandidatePathReader: CandidatePathReading {
  public init() {}

  public func readCandidate(
    from path: URL,
    stagingDirectory: URL,
    attemptStartedAt: Date,
    requiresObjectPayload: Bool,
    routingReconciler: OutputContractRoutingReconciler? = nil
  ) async throws -> RuntimeOutputCandidate {
    let standardizedPath = path.standardizedFileURL.resolvingSymlinksInPath()
    let standardizedStagingDirectory = stagingDirectory.standardizedFileURL.resolvingSymlinksInPath()
    guard isFileURL(standardizedPath, inside: standardizedStagingDirectory) else {
      throw RuntimeOutputCandidateError.candidatePathOutsideStaging(standardizedPath.path)
    }
    guard FileManager.default.fileExists(atPath: standardizedPath.path) else {
      throw RuntimeOutputCandidateError.missingCandidatePath(standardizedPath.path)
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: standardizedPath.path)
    if let modifiedAt = attributes[.modificationDate] as? Date, modifiedAt < attemptStartedAt {
      throw RuntimeOutputCandidateError.staleCandidatePath(standardizedPath.path)
    }

    let data = try Data(contentsOf: standardizedPath)
    let decoded: JSONValue
    do {
      decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      throw RuntimeOutputCandidateError.malformedCandidateJSON(error.localizedDescription)
    }
    guard case let .object(object) = decoded else {
      throw RuntimeOutputCandidateError.nonObjectCandidate(standardizedPath.path)
    }
    let normalized = try normalizeOutputContractEnvelope(
      object,
      source: "candidatePath",
      routingReconciler: routingReconciler
    )
    let extracted = try extractHandoverEnvelope(normalized.payload, source: "candidatePath")
    return RuntimeOutputCandidate(
      source: .candidatePath(standardizedPath),
      payload: extracted.payload,
      completionPassed: normalized.completionPassed,
      when: normalized.when,
      routingDiagnostics: normalized.routingDiagnostics,
      handover: extracted.handover
    )
  }
}

public func normalizeRuntimeInlineCandidate(
  _ object: JSONObject,
  routingReconciler: OutputContractRoutingReconciler? = nil
) throws -> RuntimeOutputCandidate {
  let normalized = try normalizeOutputContractEnvelope(
    object,
    source: "inlineCandidate",
    routingReconciler: routingReconciler
  )
  let extracted = try extractHandoverEnvelope(normalized.payload, source: "inlineCandidate")
  return RuntimeOutputCandidate(
    source: .inlineCandidate,
    payload: extracted.payload,
    completionPassed: normalized.completionPassed,
    when: normalized.when,
    routingDiagnostics: normalized.routingDiagnostics,
    handover: extracted.handover
  )
}

public func normalizeRuntimeAdapterOutput(
  _ output: AdapterExecutionOutput,
  routingReconciler: OutputContractRoutingReconciler? = nil
) throws -> RuntimeOutputCandidate {
  let normalized = try normalizeOutputContractEnvelope(
    output.payload,
    source: "adapterOutput",
    defaults: (output.completionPassed, output.when),
    routingReconciler: routingReconciler
  )
  let extracted = try extractHandoverEnvelope(normalized.payload, source: "adapterOutput")
  return RuntimeOutputCandidate(
    source: .adapterOutput,
    payload: extracted.payload,
    completionPassed: normalized.completionPassed,
    when: normalized.when,
    routingDiagnostics: normalized.routingDiagnostics,
    handover: extracted.handover
  )
}

public func extractHandoverEnvelope(
  _ payload: JSONObject,
  source: String
) throws -> (payload: JSONObject, handover: HandoverEnvelope?) {
  var businessPayload = payload
  guard let value = businessPayload.removeValue(forKey: HandoverEnvelope.reservedKey) else {
    return (businessPayload, nil)
  }
  return (businessPayload, try HandoverEnvelope.parse(value, source: source))
}

private func isFileURL(_ url: URL, inside directory: URL) -> Bool {
  let path = url.path
  let directoryPath = directory.path
  return path == directoryPath || path.hasPrefix(directoryPath + "/")
}
