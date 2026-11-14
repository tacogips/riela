# Riela Note plan ownership audit (2026-09-23)

This is a routing audit, not an implementation-acceptance decision. Riela
commit `d4268c34` (merged by `817ed12`, PR #86) removed the local
`Sources/RielaNote`, `Sources/RielaNoteUI`, and `Tests/RielaNoteTests`
implementation. Current Riela retains Kaiba-facing add-ons and workflows;
`cb01478b` restored graph-RAG examples on the `kaiba/*` add-on boundary.
Do not dispatch a plan against removed Riela source paths or archive it only
because its old paths are absent.

| Active Riela plan | Current evidence | Disposition before implementation |
| --- | --- | --- |
| `riela-note-new-features` | Its 33 unchecked items still target the old Riela Note stack. Kaiba `impl-plans/completed/note-capture-and-entity-pages.md` closes F1 Anywhere Capture and F2 Entity Pages; its completion is on Kaiba `origin/main` via `2949ba7`. | Reconcile F1/F2 against the accepted Riela design, then split out or rebase the unresolved F3 Scoped Ask. Do not implement F1/F2 again in Riela. |
| `riela-note-graph-rag` | The plan says ready, but Riela commits `ef43924e` and `b33f922f` implemented and hardened graph-RAG before extraction; the code/tests were removed at `d4268c34`, while examples were restored at `cb01478b`. Kaiba's active `note-retrieval-fusion` says implemented, but that status alone does not prove this plan's accepted contract. | Compare the accepted graph-RAG behavior with current Kaiba APIs/tests and Riela examples before deciding which checklist items are complete or still owned by Kaiba. |
| `riela-note-notebook-expand` | The plan says implemented; `40ec3428` delivered the Riela implementation and its Note tests were later extracted. | Verify Kaiba parity and archive as historical Riela work only after checking its current owner and evidence. |
| `riela-note-system-memory` | The old plan targets local Note system memory; `81542b5a` added it before extraction and `987c8a4` later split short-term Riela memory from Kaiba long-term memory. | Reconcile against the post-split architecture; do not replay its old removal/migration steps. |
| `riela-note` | Its remaining baseline deferrals refer to the former local Note substrate. | Reassign each deferral to the actual current Riela or Kaiba owner and trigger before closing or moving the plan. |

Kaiba's local `main` was ahead of `origin/main` by three commits and had
untracked `.riela/` state at audit time. That checkout belongs to another
session and was inspected read-only; this audit neither merges nor modifies
Kaiba. No Riela active Note plan is declared complete by this audit.
