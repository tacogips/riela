# User QA: YouTube processing built-ins

Design: `design-docs/specs/design-youtube-processing-builtins.md`. None of
these questions blocks implementation. Each one has a chosen default that the
implementation uses unless the user overrides it.

1. **Downloader add-on name.**
   - Default: `media/yt-dlp-download`, version `1`, shipped in
     `examples/video-pipeline-yt-dlp/`.
   - Alternative: a vendor namespace such as `tacogips/yt-dlp-download`.
2. **Validation of shared-store add-ons outside the owning package.**
   - Decided (follow-up): workflows outside any package validate against
     container add-ons installed in project/user packages or the shared store,
     matching runtime resolution. Package-owned workflows still require their own
     `addons[]` or a node-addon dependency lock. ART uses this path.
3. **Removal release for `riela/media-download`.**
   - Decided 2026-10-30: removed now, without backward compatibility or a
     migration alias. Workflows must use a package downloader such as
     `media/yt-dlp-download`.
4. **youtube-collect filter scope.**
   - Default: `excludeLive` and `maxDurationSeconds` apply to explicit videos as
     well as channel uploads.
   - Alternative: apply them to channel uploads only, mirroring
     `publishedAfter`.
