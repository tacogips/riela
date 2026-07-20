import RielaNote

/// Human-readable message for a list load/selection failure. `NoteServiceError`
/// cases map to short user-facing text; anything else falls back to a generic
/// message so raw error descriptions never reach the UI.
func rielaNoteLoadFailureMessage(_ error: Error) -> String {
  switch error {
  case RielaNoteUIClientCapabilityError.notebookNotesWindowUnsupported:
    return "This note source cannot open a bounded reader window."
  case let serviceError as NoteServiceError:
    switch serviceError {
    case .notFound:
      return "That note is no longer available."
    case .readOnly:
      return "This note is read-only."
    case .protectedTag:
      return "That tag can't be changed."
    case .invalidInput:
      return "The request was invalid."
    case .invalidRow:
      return "A stored note could not be read."
    }
  default:
    return "Unable to load notes right now."
  }
}
