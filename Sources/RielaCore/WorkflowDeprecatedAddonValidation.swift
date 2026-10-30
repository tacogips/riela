func deprecatedAddonDiagnostics(_ addon: WorkflowNodeAddonRef?, nodeId: String) -> [WorkflowValidationDiagnostic] {
  guard addon?.name == "riela/media-download" else { return [] }
  return [.init(
    severity: .warning,
    path: "workflow.nodes.\(nodeId).addon.name",
    message: "riela/media-download is deprecated; install an adaptable downloader add-on such as "
      + "media/yt-dlp-download and wire its mediaDownload.path (see docs/workflows/video-pipeline.md, "
      + "Migrating from riela/media-download)"
  )]
}
