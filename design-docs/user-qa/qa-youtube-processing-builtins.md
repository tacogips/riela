# User QA: YouTube processing built-ins

Design: `design-docs/specs/design-youtube-processing-builtins.md`. None of
these questions blocks implementation. Each one has a chosen default that the
implementation uses unless the user overrides it.

1. **Downloader add-on name.**
   - Default: `media/yt-dlp-download`, version `1`, shipped in
     `examples/video-pipeline-yt-dlp/`.
   - Alternative: a vendor namespace such as `tacogips/yt-dlp-download`.
2. **Validation of shared-store add-ons outside the owning package.**
   - Default: unchanged. `workflow validate` resolves a third-party add-on only
     through the owning package's `addons[]` or a node-addon dependency lock.
     The runtime also resolves it from the shared store. ART migrates by
     vendoring the add-on into its package or adding a dependency lock.
   - Alternative, out of scope here: let validation accept shared-store add-ons
     directly.
3. **Removal release for `riela/media-download`.**
   - Default: keep it deprecated and warning for this release; removal is not
     scheduled.
   - The user decides the removal release after ART migrates.
4. **youtube-collect filter scope.**
   - Default: `excludeLive` and `maxDurationSeconds` apply to explicit videos as
     well as channel uploads.
   - Alternative: apply them to channel uploads only, mirroring
     `publishedAfter`.
