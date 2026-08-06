import Foundation

struct GitTerminalJournalMarker: Codable, Equatable {
  var schemaVersion: Int
  var journalKey: String
  var workflowExecutionId: String
  var stepExecutionId: String
}

private struct GitTerminalJournalCandidate {
  var journalKey: String
  var workflowExecutionId: String
  var stepExecutionId: String
}

extension GitFinalizationStore {
  func recordTerminalWorkflowExecution(
    _ workflowExecutionId: String,
    stepExecutionIds: [String],
    repository: GitRepositoryIdentity
  ) throws {
    guard !workflowExecutionId.isEmpty,
          workflowExecutionId.utf8.count <= 4_096 else {
      throw policyError("git finalization terminal workflow identity is invalid")
    }
    try prepare()
    let candidates = try terminalJournalCandidates(
      workflowExecutionId: workflowExecutionId,
      repository: repository
    )
    guard !candidates.isEmpty else { return }
    let candidateStepExecutionIds = Set(candidates.map(\.stepExecutionId))
    var eligibleStepExecutionIds: Set<String> = []
    for stepExecutionId in stepExecutionIds {
      try checkGitFinalizationFilesystemDeadline()
      guard !stepExecutionId.isEmpty, stepExecutionId.utf8.count <= 4_096 else {
        throw policyError("git finalization terminal workflow identity is invalid")
      }
      if candidateStepExecutionIds.contains(stepExecutionId) {
        eligibleStepExecutionIds.insert(stepExecutionId)
      }
    }

    var wroteMarker = false
    for candidate in candidates where eligibleStepExecutionIds.contains(candidate.stepExecutionId) {
      let marker = GitTerminalJournalMarker(
        schemaVersion: 1,
        journalKey: candidate.journalKey,
        workflowExecutionId: candidate.workflowExecutionId,
        stepExecutionId: candidate.stepExecutionId
      )
      try writeCreateOnly(
        try canonicalData(marker),
        to: terminalJournalMarkerURL(candidate.journalKey),
        maxBytes: 16 * 1_024
      )
      wroteMarker = true
    }
    if wroteMarker {
      try garbageCollectFailedArtifacts()
    }
  }

  private func terminalJournalCandidates(
    workflowExecutionId: String,
    repository: GitRepositoryIdentity
  ) throws -> [GitTerminalJournalCandidate] {
    var candidates: [GitTerminalJournalCandidate] = []
    for journalURL in try managedDirectoryEntries(
      at: journalsDirectory,
      maximumEntries: 4_096
    ) {
      guard let journal = try? decodeBounded(
        GitCommitJournal.self,
        from: journalURL,
        maxBytes: 512 * 1_024
      ),
      journalURL.lastPathComponent == journal.journalKey + ".json",
      journal.workflowExecutionId == workflowExecutionId,
      journal.repository.matchesAfterIndexPublication(repository) else {
        continue
      }
      candidates.append(GitTerminalJournalCandidate(
        journalKey: journal.journalKey,
        workflowExecutionId: journal.workflowExecutionId,
        stepExecutionId: journal.stepExecutionId
      ))
    }
    return candidates
  }

  func terminalJournalMarkers(entryLimit: Int) throws -> [String: GitTerminalJournalMarker] {
    let markerURLs = try managedDirectoryEntries(
      at: terminalDirectory,
      maximumEntries: entryLimit
    )
    return Dictionary(uniqueKeysWithValues: markerURLs.compactMap { markerURL in
      guard let marker = try? decodeBounded(
        GitTerminalJournalMarker.self,
        from: markerURL,
        maxBytes: 16 * 1_024
      ),
      marker.schemaVersion == 1,
      markerURL == terminalJournalMarkerURL(marker.journalKey) else {
        return nil
      }
      return (marker.journalKey, marker)
    })
  }

  func removeUnusedTerminalJournalMarkers(entryLimit: Int) throws {
    let retainedJournalKeys = Set(try managedDirectoryEntries(
      at: journalsDirectory,
      maximumEntries: entryLimit
    ).map { $0.deletingPathExtension().lastPathComponent })
    var removedMarker = false
    for markerURL in try managedDirectoryEntries(
      at: terminalDirectory,
      maximumEntries: entryLimit
    ) {
      try checkGitFinalizationFilesystemDeadline()
      guard let marker = try? decodeBounded(
        GitTerminalJournalMarker.self,
        from: markerURL,
        maxBytes: 16 * 1_024
      ),
      marker.schemaVersion == 1,
      markerURL == terminalJournalMarkerURL(marker.journalKey),
      !retainedJournalKeys.contains(marker.journalKey),
      let snapshot = try managedFileSnapshot(at: markerURL) else {
        continue
      }
      if try removeManagedEntryIfUnchanged(at: markerURL, expected: snapshot) {
        removedMarker = true
      }
    }
    if removedMarker {
      try synchronizeDirectory(terminalDirectory)
    }
  }

  private func terminalJournalMarkerURL(_ journalKey: String) -> URL {
    terminalDirectory.appendingPathComponent(journalKey + ".json")
  }
}
