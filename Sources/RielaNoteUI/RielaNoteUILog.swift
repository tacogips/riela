import os

/// Shared logger for the note UI. Raw error descriptions are logged here (not
/// shown in banners), so a human-readable message can reach the user while the
/// underlying detail stays available for diagnosis.
let rielaNoteUILogger = Logger(subsystem: "riela.note.ui", category: "note-ui")

/// Records an error's raw description to the log and returns nothing; callers pair
/// this with a human-readable banner message so the diagnostic detail never leaks
/// into UI-facing text.
@inline(__always)
func rielaNoteLogUIError(_ context: String, _ error: Error) {
  rielaNoteUILogger.error("\(context, privacy: .public): \(String(describing: error), privacy: .private)")
}
