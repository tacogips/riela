# Expected results

Validation has no errors. The run starts with Aoi Incident Lead, then uses at most one unvisited teammate per handoff and stops after all three have replied.
The manager selects run_workflow. Riela scaffolds a normal workflow bundle with an external prompt file, registers it as mutable, executes it by its generated id, and returns its output to the room.
Memory read/write nodes use the SQLite-backed persona-chat-memory database under the configured memory root.
Each read node targets a single declared personaId; each write node persists only the acting persona's entries and arbitrates handoff_<persona-id> flags from the configured teamPersonaIds.
