import RielaNote

public struct RielaNotePagerNoteSnapshot: Equatable {
  public let notes: [Note]
  public let selectedNoteId: String?
  public let hasMoreNotes: Bool

  public init(notes: [Note], selectedNoteId: String?, hasMoreNotes: Bool) {
    self.notes = notes
    self.selectedNoteId = selectedNoteId
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
    hasMoreNotes ? "\(notes.count)+" : "\(notes.count)"
  }

  public var selectedPositionText: String? {
    guard let currentIndex, !notes.isEmpty else {
      return nil
    }
    return "#\(currentIndex + 1) of \(totalText)"
  }

  public var canSelectPrevious: Bool {
    guard let currentIndex else {
      return false
    }
    return currentIndex > 0
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
    return "\(index + 1)/\(totalText)"
  }
}
