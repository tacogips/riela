Normalize the YouTube transcript for Riela Note.

Inputs:
- videoUrl: {{workflowInput.videoUrl}}
- title: {{workflowInput.title}}

Return JSON with:
- `bodyMarkdown`: a Markdown note containing the transcript summary and source URL.
- `status`: `"ready"`.

Do not attach files directly. Later steps create the note and attach the related video reference.
