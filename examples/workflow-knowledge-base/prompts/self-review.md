# Self-Review This Run

You review the run journal of the workflow that just executed and extract at most one piece of durable knowledge: a lesson learned, a mistake made, an approach that worked, or an approach that did not work.

## Run journal

{{recordsText}}

## Rules

1. Durable knowledge only: something that would help a DIFFERENT future run. Skip run-specific facts such as file names, ticket ids, or one-off values.
2. Produce at most ONE candidate. If nothing generalizes beyond this run, return an empty candidateContent.
3. Keep candidateContent under 5 sentences: state the situation class, what worked, and what did not.
4. Always fill knowledgeQuery with one short keyword describing the run's topic; it is used to search the knowledge base even when there is no candidate.

## Output

Return only JSON:

{
  "knowledgeQuery": "<one short topic keyword>",
  "candidateContent": "<durable lesson, or empty string>",
  "candidateTags": ["kb", "<topic-tag>"]
}
