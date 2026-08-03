# Expected results

Validation has no errors. The run starts with Nao Procurement Lead, then uses at most one unvisited teammate per handoff and stops after all three have replied.
The fixture selects the llm_only branch.
Each memory payload includes actorPersonaId, targetPersonaId, operation, and allowed=true authorization evidence.
No actor writes a teammate's memory; specialists never read a teammate's memory.
