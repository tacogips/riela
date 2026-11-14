import { Database } from "bun:sqlite";
import { mkdir, open, rename } from "node:fs/promises";
import { dirname } from "node:path";
import { parseParticipants } from "./participants";
import {
	type CollaborationState,
	type CollaborationStateStore,
	type LaunchIntent,
	LaunchKind,
	nonemptyString,
	type PublicationRequest,
	record,
} from "./types";

function nullableString(value: unknown, label: string): string | null {
	return value === null ? null : nonemptyString(value, label);
}
function publication(value: unknown): PublicationRequest {
	const raw = record(value, "publication request");
	const idempotencyKey = nonemptyString(
		raw["idempotencyKey"],
		"publication.key",
	);
	if (!/^[!-~]{1,128}$/.test(idempotencyKey))
		throw new Error("Invalid publication key");
	return {
		content: nonemptyString(raw["content"], "publication.content"),
		idempotencyKey,
		messageId: nullableString(raw["messageId"], "publication.messageId"),
	};
}
export function parseState(value: unknown): CollaborationState {
	const raw = record(value, "state");
	if (raw["version"] !== 2)
		throw new Error(
			"Unsupported state version; retain previous state for reconciliation",
		);
	const participants = parseParticipants(raw["participants"]);
	const authors = record(raw["authors"], "state.authors");
	const personas = Object.fromEntries(
		Object.entries(record(authors["personas"], "authors.personas")).map(
			([k, v]) => [k, nonemptyString(v, "author")],
		),
	);
	const task = record(raw["task"], "state.task");
	const status = task["status"];
	if (status !== "open" && status !== "in_progress" && status !== "done")
		throw new Error("Invalid task status");
	if (typeof task["description"] !== "string")
		throw new Error("Invalid task description");
	const turns = Object.fromEntries(
		Object.entries(record(raw["turns"], "state.turns")).map(([k, v]) => {
			if (!participants.some((p) => p.stepId === k))
				throw new Error("State contains an unknown participant turn");
			return [k, publication(v)];
		}),
	);
	if (!Array.isArray(raw["launches"]))
		throw new Error("state.launches must be an array");
	const launches = raw["launches"].map((item): LaunchIntent => {
		const launch = record(item, "launch");
		const id = nonemptyString(launch["id"], "launch.id");
		if (!/^[a-f0-9-]{36}$/.test(id)) throw new Error("Invalid launch identity");
		const kind = launch["kind"];
		if (kind !== LaunchKind.Initial && kind !== LaunchKind.Recovery)
			throw new Error("Invalid launch kind");
		const sourceSessionId = nullableString(
			launch["sourceSessionId"],
			"launch.sourceSessionId",
		);
		const stepId = nullableString(launch["stepId"], "launch.stepId");
		if (
			kind === LaunchKind.Initial
				? sourceSessionId !== null || stepId !== null
				: !sourceSessionId || !participants.some((p) => p.stepId === stepId)
		)
			throw new Error("Invalid launch lineage");
		return {
			id,
			kind,
			sourceSessionId,
			stepId,
			sessionId: nullableString(launch["sessionId"], "launch.sessionId"),
		};
	});
	if (new Set(launches.map((l) => l.id)).size !== launches.length)
		throw new Error("Duplicate launch identity");
	for (const [i, l] of launches.entries()) {
		if (
			i === 0
				? l.kind !== LaunchKind.Initial
				: l.kind !== LaunchKind.Recovery ||
					l.sourceSessionId !== launches[i - 1]?.sessionId
		)
			throw new Error("Invalid launch lineage");
		if (i < launches.length - 1 && !l.sessionId)
			throw new Error("Unreconciled prior launch");
	}
	const taskId = nonemptyString(raw["taskId"], "state.taskId");
	if (task["id"] !== taskId) throw new Error("Task snapshot identity mismatch");
	return {
		version: 2,
		taskId,
		channelId: nonemptyString(raw["channelId"], "state.channelId"),
		participants,
		authors: {
			coordinator: nonemptyString(authors["coordinator"], "coordinator"),
			personas,
		},
		task: {
			id: taskId,
			title: nonemptyString(task["title"], "task.title"),
			description: task["description"],
			status,
		},
		root: publication(raw["root"]),
		turns,
		launches,
	};
}

/** SQLite's process-owned lock is released by the OS after a crash. */
export async function withStateWriter<T>(
	path: string,
	operation: () => Promise<T>,
): Promise<T> {
	await mkdir(dirname(path), { recursive: true });
	const database = new Database(path);
	try {
		try {
			database.exec("PRAGMA busy_timeout=0; BEGIN IMMEDIATE");
		} catch {
			throw new Error(
				"Another collaboration runner owns this state directory; wait for it to exit",
			);
		}
		return await operation();
	} finally {
		database.close();
	}
}

/** Sync file and directory around atomic rename before allowing downstream effects. */
export class JsonCollaborationStateStore implements CollaborationStateStore {
	constructor(readonly path: string) {}
	async load(): Promise<CollaborationState | null> {
		const file = Bun.file(this.path);
		return (await file.exists()) ? parseState(await file.json()) : null;
	}
	async save(state: CollaborationState): Promise<void> {
		await mkdir(dirname(this.path), { recursive: true });
		const temporary = `${this.path}.${crypto.randomUUID()}.tmp`;
		const file = await open(temporary, "wx", 0o600);
		try {
			await file.writeFile(JSON.stringify(state, null, 2) + "\n");
			await file.sync();
		} finally {
			await file.close();
		}
		await rename(temporary, this.path);
		const directory = await open(dirname(this.path), "r");
		try {
			await directory.sync();
		} finally {
			await directory.close();
		}
	}
}
