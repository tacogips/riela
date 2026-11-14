import { describe, expect, test } from "bun:test";
import { FakeMonjaServer } from "./fake-monja";
import scenario from "./mock-scenario.json";
import { HttpMonjaGateway } from "./monja";
import { parseParticipants } from "./participants";
import participantFixture from "./participants.json";
import { CollaborationRunner } from "./runner";
import { parseState } from "./state";
import {
	type CollaborationConfig,
	type CollaborationState,
	type CollaborationStateStore,
	type LaunchIntent,
	LaunchKind,
	type MonjaTask,
	type ParticipantConfig,
	type RielaSessionRunner,
	type RielaSessionView,
	record,
	SessionStatus,
} from "./types";

const participants = parseParticipants(participantFixture);
const payloads: readonly unknown[] = participants.map(
	(p) => record(record(scenario)[p.stepId])["payload"],
);
class MemoryStore implements CollaborationStateStore {
	state: CollaborationState | null = null;
	fail: ((state: CollaborationState) => boolean) | null = null;
	async load(): Promise<CollaborationState | null> {
		return structuredClone(this.state);
	}
	async save(state: CollaborationState): Promise<void> {
		if (this.fail?.(state)) {
			this.fail = null;
			throw new Error("injected state save interruption");
		}
		this.state = parseState(structuredClone(state));
	}
}
class FixtureRiela implements RielaSessionRunner {
	launches = 0;
	reconciliations = 0;
	failed = false;
	recoveryFails = false;
	readonly sessions = new Map<string, string>();
	constructor(
		readonly store: MemoryStore,
		readonly configured = participants,
		readonly outputs = payloads,
	) {}
	async preflight(_participants: readonly ParticipantConfig[]): Promise<void> {}
	async launch(_task: MonjaTask, intent: LaunchIntent): Promise<string> {
		expect(this.store.state?.launches.at(-1)).toEqual(intent);
		this.launches++;
		const sessionId = `session-${this.launches}`;
		this.sessions.set(intent.id, sessionId);
		return sessionId;
	}
	async reconcile(intent: LaunchIntent): Promise<string> {
		this.reconciliations++;
		const sessionId = this.sessions.get(intent.id);
		if (!sessionId) throw new Error("Indeterminate launch");
		return sessionId;
	}
	async inspect(sessionId: string): Promise<RielaSessionView> {
		const failed =
			this.failed && (sessionId === "session-1" || this.recoveryFails);
		return {
			sessionId,
			status: failed ? SessionStatus.Failed : SessionStatus.Completed,
			failureReason: failed ? "invalid final output" : null,
			executions: this.configured.map((p, i) => ({
				stepId: p.stepId,
				status: failed && p.finalDecision ? "failed" : "completed",
				acceptedPayload: failed && p.finalDecision ? null : this.outputs[i],
			})),
		};
	}
}
async function fixture(
	operation: (value: {
		server: FakeMonjaServer;
		store: MemoryStore;
		riela: FixtureRiela;
		runner: CollaborationRunner;
		config: CollaborationConfig;
	}) => Promise<void>,
): Promise<void> {
	const server = new FakeMonjaServer(),
		store = new MemoryStore(),
		riela = new FixtureRiela(store);
	const gateway = new HttpMonjaGateway(server.apiUrl, {
		coordinator: server.credentials.coordinator,
		personas: Object.fromEntries(
			participants.map((p) => [
				p.stepId,
				server.credentials[p.stepId] ?? "missing",
			]),
		),
	});
	const runner = new CollaborationRunner(gateway, riela, store);
	const config: CollaborationConfig = {
		taskId: server.task.id,
		channelId: server.channelId,
		participants,
		retryFailedStep: false,
		completeTaskOnSuccess: true,
		pollIntervalMs: 1,
		timeoutMs: 1000,
	};
	try {
		await operation({ server, store, riela, runner, config });
	} finally {
		server.stop();
	}
}
describe("Durable configurable collaboration", () => {
	test("a valid constructor step runs without inherited-object publication collisions", () =>
		fixture(async ({ server, store, config }) => {
			server.addParticipant("constructor");
			const configured = participants.map((p, i) =>
				i === 0 ? { ...p, stepId: "constructor" } : p,
			);
			const outputs = payloads.map((value, i) => {
				const payload = record(structuredClone(value));
				if (i === 0) payload["persona"] = "constructor";
				const prior = payload["priorTurns"] as Record<string, unknown>[];
				for (const turn of prior)
					if (turn["persona"] === "architect") turn["persona"] = "constructor";
				return payload;
			});
			const gateway = new HttpMonjaGateway(server.apiUrl, {
				coordinator: server.credentials.coordinator,
				personas: Object.fromEntries(
					configured.map((p) => [
						p.stepId,
						server.credentials[p.stepId] ?? "missing",
					]),
				),
			});
			const runner = new CollaborationRunner(
				gateway,
				new FixtureRiela(store, configured, outputs),
				store,
			);
			await runner.run({ ...config, participants: configured });
			expect(server.messages).toHaveLength(4);
			expect(server.messages[1]?.authorId).toBe("fixture-constructor-user");
		}));
	test("same bot under distinct token names is rejected before publication", () =>
		fixture(async ({ server, store, riela, config }) => {
			const gateway = new HttpMonjaGateway(server.apiUrl, {
				coordinator: server.credentials.coordinator,
				personas: Object.fromEntries(
					participants.map((p) => [p.stepId, server.credentials.architect]),
				),
			});
			await expect(
				new CollaborationRunner(gateway, riela, store).run(config),
			).rejects.toThrow("distinct bot authors");
			expect(server.messages).toHaveLength(0);
			expect(riela.launches).toBe(0);
		}));
	test("successful restart retains exact thread, task, and session with no new calls/posts", () =>
		fixture(async ({ server, riela, runner, config }) => {
			const first = await runner.run(config),
				second = await runner.run(config);
			expect(second).toEqual(first);
			expect(riela.launches).toBe(1);
			expect(server.messages).toHaveLength(4);
			expect(server.completionCalls).toBe(1);
		}));
	test("recovers initial session-ID save crash from durable intent without another model launch", () =>
		fixture(async ({ store, riela, runner, config, server }) => {
			store.fail = (state) =>
				state.launches.at(-1)?.sessionId !== null && state.launches.length > 0;
			await expect(runner.run(config)).rejects.toThrow("interruption");
			expect(store.state?.launches.at(-1)?.sessionId).toBeNull();
			await runner.run(config);
			expect(riela.launches).toBe(1);
			expect(riela.reconciliations).toBe(1);
			expect(server.messages).toHaveLength(4);
		}));
	test("uncertain root commit reconciles original immutable request after task title changes", () =>
		fixture(async ({ runner, config, server, store }) => {
			server.loseNextMessageResponse = true;
			await expect(runner.run(config)).rejects.toThrow("503");
			expect(store.state?.root.messageId).toBeNull();
			expect(server.messages).toHaveLength(1);
			Object.assign(server.task, { title: "Edited task title" });
			await runner.run(config);
			expect(server.messages).toHaveLength(4);
		}));
	test("uncertain reply commit uses the same publication request and one canonical reply", () =>
		fixture(async ({ runner, config, server, store }) => {
			store.fail = (state) => {
				if (
					Object.keys(state.turns).length === 1 &&
					state.turns["architect"]?.messageId === null
				) {
					server.loseNextMessageResponse = true;
					store.fail = null;
				}
				return false;
			};
			await expect(runner.run(config)).rejects.toThrow("503");
			await runner.run(config);
			expect(server.messages).toHaveLength(4);
		}));
	test("failed final step is terminal until explicit bounded history-preserving retry", () =>
		fixture(async ({ runner, riela, config, server, store }) => {
			riela.failed = true;
			await expect(runner.run(config)).rejects.toThrow("explicit retry");
			expect(server.messages).toHaveLength(3);
			expect(riela.launches).toBe(1);
			const source = store.state?.launches[0]?.sessionId;
			await runner.run({ ...config, retryFailedStep: true });
			expect(riela.launches).toBe(2);
			expect(server.messages).toHaveLength(4);
			expect(store.state?.launches[1]).toMatchObject({
				kind: LaunchKind.Recovery,
				sourceSessionId: source,
				stepId: "integrator",
			});
		}));
	test("recovery session-ID save crash reconciles once without rerunning accepted agents", () =>
		fixture(async ({ runner, riela, config, store, server }) => {
			riela.failed = true;
			await expect(runner.run(config)).rejects.toThrow("failed");
			store.fail = (state) =>
				state.launches.length === 2 &&
				state.launches.at(-1)?.sessionId !== null;
			await expect(
				runner.run({ ...config, retryFailedStep: true }),
			).rejects.toThrow("interruption");
			await runner.run({ ...config, retryFailedStep: true });
			expect(riela.launches).toBe(2);
			expect(riela.reconciliations).toBe(1);
			expect(server.messages).toHaveLength(4);
		}));
	test("retry remains bounded to one recovery attempt per invocation", () =>
		fixture(async ({ runner, riela, config, server }) => {
			riela.failed = true;
			riela.recoveryFails = true;
			await expect(
				runner.run({ ...config, retryFailedStep: true }),
			).rejects.toThrow("failed");
			expect(riela.launches).toBe(2);
			expect(server.messages).toHaveLength(3);
			expect(server.completionCalls).toBe(0);
		}));
	test("indeterminate launch refuses a second launch", () =>
		fixture(async ({ runner, riela, store, config }) => {
			store.fail = (state) =>
				state.launches.length === 1 && state.launches[0]?.sessionId !== null;
			await expect(runner.run(config)).rejects.toThrow("interruption");
			riela.sessions.clear();
			await expect(runner.run(config)).rejects.toThrow("Indeterminate");
			expect(riela.launches).toBe(1);
		}));
	test("invalid participant configuration fails before any network or launch", () =>
		fixture(async ({ runner, config, server, riela }) => {
			await expect(
				runner.run({
					...config,
					participants: [...participants, participants[0] as ParticipantConfig],
				}),
			).rejects.toThrow("distinct");
			expect(server.requests).toHaveLength(0);
			expect(riela.launches).toBe(0);
		}));
	test("incompatible participant restart fails before network", () =>
		fixture(async ({ runner, config, server }) => {
			await runner.run(config);
			const count = server.requests.length;
			await expect(
				runner.run({
					...config,
					participants: participants.map((p) => ({
						...p,
						displayName: p.displayName + "changed",
					})),
				}),
			).rejects.toThrow("configuration");
			expect(server.requests).toHaveLength(count);
		}));
	test("rejects tampered canonical content and author after publication", () =>
		fixture(async ({ runner, config, server }) => {
			await runner.run(config);
			const reply = server.messages[1];
			if (!reply) throw new Error("missing fixture reply");
			Object.assign(reply, { content: "tampered", authorId: "other" });
			await expect(runner.run(config)).rejects.toThrow(
				"invalid id, channel, parent, author, or content",
			);
			expect(server.completionCalls).toBe(1);
		}));
});
