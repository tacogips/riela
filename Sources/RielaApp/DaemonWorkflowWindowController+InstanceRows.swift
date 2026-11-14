#if os(macOS)
import AppKit
import RielaAppSupport

extension DaemonWorkflowWindowController {
  var instanceRows: [ConfiguredWorkflowInstanceRow] {
    cachedInstanceRows
  }

  @discardableResult
  func rebuildInstanceRows() -> Bool {
    let rawRows = makeInstanceRows()
    rawInstanceRowsCount = rawRows.count
    let rows = filteredInstanceRows(rawRows)
    let fingerprint = instanceRowsFingerprint(for: rows)
    let changed = fingerprint != instanceRowsFingerprint
    cachedInstanceRows = rows
    instanceRowsFingerprint = fingerprint
    return changed
  }

  private func makeInstanceRows() -> [ConfiguredWorkflowInstanceRow] {
    if !profileInstances.isEmpty {
      return profiledInstanceRows()
    }
    let allCandidates = candidates + workflowSources
    let candidatesById = Dictionary(allCandidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let candidatesBySourceIdentity = Dictionary(
      allCandidates.map { ($0.sourceIdentity, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    return state.preferences
      .sorted { lhs, rhs in lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending }
      .map { identity, preference in
        let storedIdentity = preference.identity.isEmpty ? identity : preference.identity
        let sourceIdentity = preference.sourceIdentity ?? storedIdentity
        let sourceCandidate = candidatesById[sourceIdentity] ?? candidatesBySourceIdentity[sourceIdentity]
        let directCandidate = candidatesById[storedIdentity]
        let candidate = directCandidate ?? sourceCandidate?.managedInstance(
          identity: storedIdentity,
          displayName: preference.displayName
        )
        let instanceName = preference.displayName?.isEmpty == false
          ? preference.displayName ?? storedIdentity
          : candidate?.displayName ?? storedIdentity
        let state = instanceState(identity: storedIdentity, hasSource: candidate != nil)
        return ConfiguredWorkflowInstanceRow(
          id: storedIdentity,
          profileName: profileName,
          localIdentity: storedIdentity,
          preference: preference,
          candidate: candidate,
          sourceIdentity: sourceIdentity,
          instanceName: instanceName,
          workflowName: sourceCandidate?.displayName ?? candidate?.workflowId ?? "Missing source",
          hasMissingRequiredEnvironment: candidate.map(hasMissingRequiredEnvironment) ?? false,
          state: state,
          stateDetail: snapshots[storedIdentity]?.detail ?? ""
        )
      }
  }

  private func instanceRowsFingerprint(for rows: [ConfiguredWorkflowInstanceRow]) -> String {
    ([instanceFilterText, String(rawInstanceRowsCount)] + rows.map { row in
      [
        row.id,
        row.profileName.rawValue,
        row.localIdentity,
        row.sourceIdentity,
        row.instanceName,
        row.workflowName,
        String(row.hasMissingRequiredEnvironment),
        row.state.rawValue,
        row.stateDetail,
        row.preference.environmentFilePath ?? "",
        row.preference.workingDirectory ?? "",
        String(row.preference.environmentVariables.count),
        String(row.preference.defaultVariables.count),
        row.candidate?.eventSourceSummary ?? ""
      ].joined(separator: "\u{1f}")
    }).joined(separator: "\u{1e}")
  }

  private func profiledInstanceRows() -> [ConfiguredWorkflowInstanceRow] {
    profileInstances
      .filter { profileFilterName == nil || $0.profileName == profileFilterName }
      .sorted { lhs, rhs in
        let profileCompare = lhs.profileName.rawValue.localizedCaseInsensitiveCompare(rhs.profileName.rawValue)
        if profileCompare != .orderedSame {
          return profileCompare == .orderedAscending
        }
        return lhs.instance.displayName.localizedCaseInsensitiveCompare(rhs.instance.displayName) == .orderedAscending
      }
      .map { profiledInstance in
        let instance = profiledInstance.instance
        let runtimeCandidate = profiledInstance.runtimeCandidate
        return ConfiguredWorkflowInstanceRow(
          id: profiledInstance.id,
          profileName: profiledInstance.profileName,
          localIdentity: instance.identity,
          preference: instance.preference,
          candidate: runtimeCandidate,
          sourceIdentity: instance.sourceIdentity,
          instanceName: instance.displayName,
          workflowName: instance.source.displayName,
          hasMissingRequiredEnvironment: hasMissingRequiredEnvironment(runtimeCandidate),
          state: instanceState(identity: profiledInstance.id, hasSource: true),
          stateDetail: snapshots[profiledInstance.id]?.detail ?? ""
        )
      }
  }

  private func filteredInstanceRows(_ rows: [ConfiguredWorkflowInstanceRow]) -> [ConfiguredWorkflowInstanceRow] {
    let query = instanceFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      return rows
    }
    return rows.filter { row in
      [
        row.instanceName,
        row.workflowName,
        row.profileName.rawValue,
        row.state.rawValue
      ].joined(separator: " ")
        .range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
  }

  private func hasMissingRequiredEnvironment(_ candidate: RielaAppDaemonWorkflowCandidate) -> Bool {
    environmentColumnStatus(candidate).hasPrefix("Missing ")
  }

  private func instanceState(identity: String, hasSource: Bool) -> InstanceState {
    guard hasSource else {
      return .needsSource
    }
    switch snapshots[identity]?.status {
    case .running:
      return .running
    case .starting:
      return .starting
    case .reloading:
      return .reloading
    case .stopping:
      return .stopping
    case .failed:
      return .failed
    case .stopped, nil:
      return .stopped
    }
  }
}
#endif
