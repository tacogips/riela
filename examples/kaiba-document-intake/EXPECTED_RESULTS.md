# Expected results

- A supported file created under `incoming/` starts one
  `kaiba-document-intake` workflow run after the stability window.
- The output includes `notebookId`, `noteIds`, `sourceFile`, `ocrRequested`,
  and `translationRequested`.
- `sourceFile.s3URL` is null for local storage and `s3://bucket/key` after an
  requested S3 migration.
- Paths outside the watcher root fail with `invalidInput` before conversion.
- With `translate: true`, the output also includes `translationNotebookId`.
