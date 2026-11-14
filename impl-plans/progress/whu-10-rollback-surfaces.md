# whu-10 rollback surfaces

- Implemented CLI rollback check, list, approve and reject, including action-specific validation and closed rollback service errors.
- Implemented the GraphQL rollback provider and restore expected-version CAS wiring. GraphQL actors are limited to user and API.
- Added CLI and GraphQL regression fixtures covering proposal creation, list, approval, rejection, superseded approval, manual approval refusal and stale restore CAS.
- WHU-INT-02: the existing generated-root-argument merge and integer decoding correction were already present; current-source contract tests are rerun as part of this dispatch.
- Completion criteria: implementation and focused validation are complete subject to the final gate logs under `tmp/workflow-history-unification/whu-10-rollback-surfaces/`. Formal integrity, adversarial and integration review, shared documentation, staging and commit remain downstream.
