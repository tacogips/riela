import { nonemptyString, type ParticipantConfig, record } from "./types";

/** Validate participant identity before network or model effects. */
export function parseParticipants(
	value: unknown,
): readonly ParticipantConfig[] {
	if (!Array.isArray(value) || value.length < 2 || value.length > 16)
		throw new Error("participants must contain 2–16 entries");
	const seenSteps = new Set<string>();
	const seenTokens = new Set<string>();
	const result = value.map((item, index): ParticipantConfig => {
		const raw = record(item, `participants[${index}]`);
		if (
			Object.keys(raw).some(
				(key) =>
					!["stepId", "displayName", "tokenEnv", "finalDecision"].includes(key),
			)
		)
			throw new Error("Unknown participant field");
		const stepId = nonemptyString(raw["stepId"], "participant.stepId");
		const displayName = nonemptyString(
			raw["displayName"],
			"participant.displayName",
		);
		const tokenEnv = nonemptyString(raw["tokenEnv"], "participant.tokenEnv");
		if (!/^[a-z0-9][a-z0-9-]{1,63}$/.test(stepId) || stepId === "root")
			throw new Error("Invalid participant stepId");
		if (
			!/^MONJA_[A-Z0-9_]+_TOKEN$/.test(tokenEnv) ||
			tokenEnv === "MONJA_API_TOKEN"
		)
			throw new Error("Participant tokenEnv must be a dedicated MONJA_*_TOKEN");
		if (seenSteps.has(stepId) || seenTokens.has(tokenEnv))
			throw new Error(
				"Participant stepIds and tokenEnv names must be distinct",
			);
		if (typeof raw["finalDecision"] !== "boolean")
			throw new Error("finalDecision must be boolean");
		seenSteps.add(stepId);
		seenTokens.add(tokenEnv);
		return {
			stepId,
			displayName,
			tokenEnv,
			finalDecision: raw["finalDecision"],
		};
	});
	if (
		result.filter((p) => p.finalDecision).length !== 1 ||
		!result.at(-1)?.finalDecision
	)
		throw new Error("Exactly the last participant must own finalDecision");
	return result;
}
