# Expected Results

Stable assertions for deterministic verification with the bundled mock scenario.
Ignore `sessionId`, timestamps, and artifact paths.

## Validate

```bash
riela workflow validate note-youtube-transcript --workflow-definition-dir ./examples
```

Expected result: the workflow is valid.

## Run

```bash
riela workflow run note-youtube-transcript \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/note-youtube-transcript/mock-scenario.json \
  --variables '{"noteRoot":"<tmp-note-root>","workflowInput":{"title":"Video Notes","videoUrl":"https://youtu.be/example","videoFilePath":"<tmp-video-file.mp4>"}}' \
  --output json
```

Expected stable result:

- `status` is `completed`.
- `workflowId` is `note-youtube-transcript`.
- One transcript note is created with the `youtube` tag.
- One related `video/mp4` attachment stores the supplied video file bytes.
- The root output is the `riela/note-attach-file` payload and includes `fileId`.
