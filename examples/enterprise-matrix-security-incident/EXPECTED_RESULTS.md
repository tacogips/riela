# Expected results

Validation has no errors. The run starts with Aoi Incident Lead, then uses at most one unvisited teammate per handoff and stops after all three have replied.
The manager selects run_workflow. Riela scaffolds a normal workflow bundle with an external prompt file, registers it as mutable, executes it by its generated id, and returns its output to the room.
Each memory payload includes actorPersonaId, targetPersonaId, operation, and allowed=true authorization evidence.
No actor writes a teammate's memory; specialists never read a teammate's memory.
