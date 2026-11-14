# Expected results

Validation has no errors. The run starts with Hana Support Lead, then uses at most one unvisited teammate per handoff and stops after all three have replied.
The fixture selects the llm_only branch.
Memory read/write nodes use the SQLite-backed persona-chat-memory database under the configured memory root.
Each read node targets a single declared personaId; each write node persists only the acting persona's entries and arbitrates handoff_<persona-id> flags from the configured teamPersonaIds.
