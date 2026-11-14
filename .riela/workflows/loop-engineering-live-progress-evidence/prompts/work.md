Implement live-progress loop evidence persistence in the Swift CLI.

Acceptance criteria:
- In-progress live session persistence includes projected `loopEvidence` when workflow loop metadata exists.
- Final persistence behavior remains unchanged.
- JSONL progress records remain backward compatible.
- Existing legacy sessions without loop metadata remain compatible.
- Tests prove the live persisted snapshot contains loop evidence before the slow command completes.
