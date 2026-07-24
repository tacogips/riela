import RielaNote

public struct RielaNotePagerNoteSnapshot: Equatable {
  public let notes: [Note]
  public let selectedNoteId: String?
  public let leadingOffset: Int
  public let hasEarlierNotes: Bool
  public let hasMoreNotes: Bool

  public init(
    notes: [Note],
    selectedNoteId: String?,
    leadingOffset: Int = 0,
    hasEarlierNotes: Bool = false,
    hasMoreNotes: Bool
  ) {
    self.notes = notes
    self.selectedNoteId = selectedNoteId
    self.leadingOffset = max(leadingOffset, 0)
    self.hasEarlierNotes = hasEarlierNotes
    self.hasMoreNotes = hasMoreNotes
  }

  public var currentIndex: Int? {
    guard let selectedNoteId else {
      return nil
    }
    return notes.firstIndex { $0.noteId == selectedNoteId }
  }

  public var totalLoadedCount: Int {
    notes.count
  }

  public var totalText: String {
    let loadedEndOffset = leadingOffset + notes.count
    return hasMoreNotes ? "\(loadedEndOffset)+" : "\(loadedEndOffset)"
  }

  public var selectedPositionText: String? {
    guard let currentIndex, !notes.isEmpty else {
      return nil
    }
    return "#\(leadingOffset + currentIndex + 1) of \(totalText)"
  }

  public var canSelectPrevious: Bool {
    guard let currentIndex else {
      return false
    }
    return currentIndex > 0 || hasEarlierNotes
  }

  public var canSelectNext: Bool {
    guard let currentIndex else {
      return false
    }
    return currentIndex + 1 < notes.count || hasMoreNotes
  }

  public var previousNote: Note? {
    guard let currentIndex else {
      return nil
    }
    let targetIndex = currentIndex - 1
    guard notes.indices.contains(targetIndex) else {
      return nil
    }
    return notes[targetIndex]
  }

  public var nextNote: Note? {
    guard let currentIndex else {
      return nil
    }
    let targetIndex = currentIndex + 1
    guard notes.indices.contains(targetIndex) else {
      return nil
    }
    return notes[targetIndex]
  }

  public func positionText(for noteId: String) -> String? {
    guard let index = notes.firstIndex(where: { $0.noteId == noteId }) else {
      return nil
    }
    return "\(leadingOffset + index + 1)/\(totalText)"
  }

  public func isWithinTrailingEdge(noteId: String, threshold: Int) -> Bool {
    guard let index = notes.firstIndex(where: { $0.noteId == noteId }), !notes.isEmpty else {
      return false
    }
    return notes.index(before: notes.endIndex) - index <= max(threshold, 0)
  }

  public func shouldLoadNextPage(visibleNoteId: String, trailingThreshold: Int) -> Bool {
    hasMoreNotes && isWithinTrailingEdge(noteId: visibleNoteId, threshold: trailingThreshold)
  }

  public func shouldLoadPreviousPage(visibleNoteId: String, leadingThreshold: Int) -> Bool {
    guard hasEarlierNotes,
          let index = notes.firstIndex(where: { $0.noteId == visibleNoteId }) else {
      return false
    }
    return index <= max(leadingThreshold, 0)
  }

  public func isCloserToTrailingEdge(noteId: String) -> Bool {
    guard let index = notes.firstIndex(where: { $0.noteId == noteId }), !notes.isEmpty else {
      return false
    }
    let trailingDistance = notes.index(before: notes.endIndex) - index
    return trailingDistance <= index
  }
}
