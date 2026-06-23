Adversarially review the current Riela memory feature design from the repository diff.

User objective:
{{workflowInput.requestedWork}}

Acceptance criteria:
{{workflowInput.acceptanceCriteria}}

Do not modify files. Return one JSON object only with keys:
- `accepted`
- `findings`
- `designDecisions`
- `requiredChanges`

Focus on whether the Python-script behavior has been generalized into Riela correctly:
- the built-in `riela/chat-memory-raw-daily-summary` add-on contract and naming
- whether it is reusable beyond one example
- whether memory metadata and `dataSchema` remain discoverable by workflow nodes
- whether tags and related ids remain bounded and pageable
- whether raw chat logs and daily summaries are correctly separated into different memory databases
- whether Telegram and Discord chat memory regression coverage proves memory still works

Also adversarially review the file-aware memory design:
- whether records can persist up to 10 local file references by copying bytes into memory-owned storage
- whether SQLite stores enough metadata to return files later
- whether MIME/kind normalization covers image, audio, video, PDF, and text without overfitting to Telegram
- whether memory-load/search/persona-read expose generic files plus typed paths for model adapters
- whether update should replace, preserve, or clear existing files explicitly
- whether file paths are safe and portable enough for local workflow execution
- whether adapter image forwarding can inspect images recalled from memory
- whether non-image file support is honestly bounded by downstream adapter capability

Also check the independent RielaMemory package, workflow/node memory declarations, workflow-id scoped save/load/search/update, JSONB payloads, one SQLite file per memory id, default registered-desc limit 30, LLM command guidance, and chat memory replacement.

Treat unrelated dirty files outside memory/add-on/example/test scope as out of scope.
