import { describe, expect, test } from "bun:test";
import { mkdtemp } from "node:fs/promises";
import { resolve } from "node:path";
import participants from "./participants.json";
import { JsonCollaborationStateStore, parseState } from "./state";
import { LaunchKind, record, stringArray } from "./types";

function state(): Record<string, unknown> {
	return {
		version: 2,
		taskId: "task",
		channelId: "channel",
		participants,
		authors: {
			coordinator: "owner",
			personas: { architect: "a", skeptic: "s", integrator: "i" },
		},
		task: { id: "task", title: "Task", description: "", status: "open" },
		root: { content: "root", idempotencyKey: "root-key", messageId: null },
		turns: {},
		launches: [],
	};
}
const initial = () => ({
	id: crypto.randomUUID(),
	kind: LaunchKind.Initial,
	sourceSessionId: null,
	stepId: null,
	sessionId: "source",
});
const recovery = () => ({
	id: crypto.randomUUID(),
	kind: LaunchKind.Recovery,
	sourceSessionId: "source",
	stepId: "integrator",
	sessionId: null,
});

describe("durable state rejects malformed evidence", () => {
	const cases: readonly [
		string,
		(raw: Record<string, unknown>) => void,
		string,
	][] = [
		[
			"version",
			(raw) => {
				raw["version"] = 1;
			},
			"Unsupported state version",
		],
		[
			"publication key",
			(raw) => {
				record(raw["root"])["idempotencyKey"] = "space key";
			},
			"Invalid publication key",
		],
		[
			"status",
			(raw) => {
				record(raw["task"])["status"] = "unknown";
			},
			"Invalid task status",
		],
		[
			"description",
			(raw) => {
				record(raw["task"])["description"] = null;
			},
			"Invalid task description",
		],
		[
			"unknown turn",
			(raw) => {
				raw["turns"] = { unknown: raw["root"] };
			},
			"unknown participant turn",
		],
		[
			"launch list",
			(raw) => {
				raw["launches"] = {};
			},
			"launches must be an array",
		],
		[
			"launch id",
			(raw) => {
				raw["launches"] = [{ ...initial(), id: "bad" }];
			},
			"Invalid launch identity",
		],
		[
			"launch kind",
			(raw) => {
				raw["launches"] = [{ ...initial(), kind: "unknown" }];
			},
			"Invalid launch kind",
		],
		[
			"initial source",
			(raw) => {
				raw["launches"] = [{ ...initial(), sourceSessionId: "unexpected" }];
			},
			"Invalid launch lineage",
		],
		[
			"initial target",
			(raw) => {
				raw["launches"] = [{ ...initial(), stepId: "integrator" }];
			},
			"Invalid launch lineage",
		],
		[
			"recovery source",
			(raw) => {
				raw["launches"] = [initial(), { ...recovery(), sourceSessionId: null }];
			},
			"Invalid launch lineage",
		],
		[
			"recovery target",
			(raw) => {
				raw["launches"] = [initial(), { ...recovery(), stepId: "unknown" }];
			},
			"Invalid launch lineage",
		],
		[
			"duplicate launch",
			(raw) => {
				const first = initial();
				raw["launches"] = [first, { ...recovery(), id: first.id }];
			},
			"Duplicate launch identity",
		],
		[
			"first recovery",
			(raw) => {
				raw["launches"] = [recovery()];
			},
			"Invalid launch lineage",
		],
		[
			"later initial",
			(raw) => {
				raw["launches"] = [initial(), initial()];
			},
			"Invalid launch lineage",
		],
		[
			"broken chain",
			(raw) => {
				raw["launches"] = [
					initial(),
					{ ...recovery(), sourceSessionId: "different" },
				];
			},
			"Invalid launch lineage",
		],
		[
			"unreconciled prefix",
			(raw) => {
				raw["launches"] = [{ ...initial(), sessionId: null }, recovery()];
			},
			"Unreconciled prior launch",
		],
		[
			"task identity",
			(raw) => {
				record(raw["task"])["id"] = "different";
			},
			"Task snapshot identity mismatch",
		],
	];
	for (const [label, mutate, message] of cases)
		test(label, () => {
			const raw = state();
			mutate(raw);
			expect(() => parseState(raw)).toThrow(message);
		});
	test("valid persisted source and pending recovery reload without changing lineage", async () => {
		const directory = await mkdtemp(
			resolve(import.meta.dir, "../../tmp/state-validation-"),
		);
		const store = new JsonCollaborationStateStore(
			resolve(directory, "state.json"),
		);
		expect(await store.load()).toBeNull();
		const parsed = parseState({
			...state(),
			launches: [initial(), recovery()],
		});
		await store.save(parsed);
		expect(await store.load()).toEqual(parsed);
		await Bun.write(store.path, JSON.stringify({ ...state(), version: 0 }));
		await expect(store.load()).rejects.toThrow("Unsupported state version");
	});
	test("string-array boundary refuses non-array values", () => {
		expect(() => stringArray({}, "list")).toThrow("list must be an array");
	});
});
