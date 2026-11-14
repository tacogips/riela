import { isDeepStrictEqual } from "node:util";
import {
	nonemptyString,
	type ParticipantConfig,
	type PersonaOutput,
	record,
	stringArray,
	type TurnRecord,
} from "./types";

/** Flat transcript projection avoids nesting each prior transcript recursively. */
export function turnRecord(output: PersonaOutput): TurnRecord {
	return {
		persona: output.persona,
		message: output.message,
		details: output.details,
	};
}
/** Role-specific details are validated by Riela's native schema. */
export function parsePersonaOutput(
	participant: ParticipantConfig,
	payload: unknown,
	prior: readonly TurnRecord[],
): PersonaOutput {
	const value = record(payload, `${participant.stepId} accepted output`);
	if (value["persona"] !== participant.stepId)
		throw new Error("Accepted output persona disagrees with configured step");
	if (
		!Array.isArray(value["priorTurns"]) ||
		!isDeepStrictEqual(value["priorTurns"], prior)
	)
		throw new Error(
			`${participant.stepId} cumulative priorTurns do not equal accepted prefix`,
		);
	const base: PersonaOutput = {
		persona: participant.stepId,
		message: nonemptyString(value["message"], "output.message"),
		details: record(value["details"], "output.details"),
		priorTurns: prior,
	};
	if (!participant.finalDecision) return base;
	if (typeof value["solved"] !== "boolean")
		throw new Error("Final solved must be boolean");
	const unresolved = stringArray(value["unresolved"], "final.unresolved");
	const acceptanceCriteria = stringArray(
		value["acceptanceCriteria"],
		"final.acceptanceCriteria",
		true,
	);
	if (value["solved"] && unresolved.length)
		throw new Error("Final solved may be true only when unresolved is empty");
	return { ...base, solved: value["solved"], unresolved, acceptanceCriteria };
}
