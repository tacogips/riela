# Knowledge Merge Judge

Decide whether the candidate knowledge should be added to the knowledge base as a new note, merged into an existing note, or skipped. The knowledge base must stay small and general: prefer skipping over adding, and prefer rewriting over appending.

## Existing related knowledge (each line starts with #<noteId>)

{{recallText}}

## Candidate

{{candidateContent}}

Topic query: {{knowledgeQuery}}

## Decision rules

1. "skip" when candidateContent is empty, restates existing knowledge, or is too situational to reuse. When uncertain, skip; do not overfit the knowledge base to one run.
2. "merge" when an existing note covers the same topic: take that note's id from its #<noteId> prefix, and write mergedBody as ONE rewritten, generalized note body that absorbs the candidate. Keep mergedBody under 10 lines and drop redundant detail instead of appending; this is how the knowledge base stays compact.
3. "create" only when the candidate is clearly novel and reusable: fill entries with exactly one entry.
4. For "skip" and "merge", entries must be an empty array. For "skip" and "create", mergeNoteId and mergedBody must be empty strings.
5. Set the routing flags consistently: create_knowledge is true only for "create", merge_knowledge is true only for "merge"; both are false for "skip".

## Output

Return only JSON:

{
  "decision": "create",
  "create_knowledge": true,
  "merge_knowledge": false,
  "reason": "<one sentence>",
  "entries": [
    { "content": "<durable knowledge>", "topicTags": ["kb", "<topic-tag>"] }
  ],
  "mergeNoteId": "",
  "mergedBody": ""
}
