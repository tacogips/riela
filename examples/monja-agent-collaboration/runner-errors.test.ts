import { describe, expect, test } from "bun:test";
import scenario from "./mock-scenario.json";
import { parseParticipants } from "./participants";
import participantFixture from "./participants.json";
import { CollaborationRunner } from "./runner";
import {
	type CollaborationConfig,
	type CollaborationState,
	type CollaborationStateStore,
	type MonjaAuthorMap,
	type MonjaGateway,
	type MonjaMessage,
	type MonjaTask,
	type RielaSessionRunner,
	type RielaSessionView,
	record,
	SessionStatus,
} from "./types";

const participants = parseParticipants(participantFixture);
const executions = participants.map((p) => ({
	stepId: p.stepId,
	status: "completed",
	acceptedPayload: record(record(scenario)[p.stepId])["payload"],
}));
class Store implements CollaborationStateStore {
	state: CollaborationState | null = null;
	async load() {
		return structuredClone(this.state);
	}
	async save(state: CollaborationState) {
		this.state = structuredClone(state);
	}
}
function fixture() {
	const store = new Store();
	const messages: MonjaMessage[] = [];
	const links = new Set<string>();
	const task: MonjaTask = {
		id: "task",
		title: "Task",
		description: "",
		status: "open",
	};
	let completed = 0,
		inspected = 0,
		threadReads = 0;
	const authors: MonjaAuthorMap = {
		coordinator: "owner",
		personas: { architect: "a", skeptic: "s", integrator: "i" },
	};
	const gateway: MonjaGateway = {
		async getExpectedAuthors() {
			return authors;
		},
		async getTask() {
			return { task, linkedMessages: messages.filter((m) => links.has(m.id)) };
		},
		async createRoot(channelId, content) {
			const m = {
				id: "root",
				channelId,
				content,
				authorId: "owner",
				parentMessageId: null,
			};
			messages.push(m);
			return m;
		},
		async postTurn(persona, channelId, rootId, content) {
			const m = {
				id: persona,
				channelId,
				content,
				authorId: authors.personas[persona] ?? "missing",
				parentMessageId: rootId,
			};
			messages.push(m);
			return m;
		},
		async getThread() {
			threadReads++;
			const root = messages[0];
			if (!root) throw Error("fixture root missing");
			return { root, replies: messages.slice(1) };
		},
		async linkTask(_task, id) {
			links.add(id);
		},
		async completeTask() {
			completed++;
		},
	};
	const riela: RielaSessionRunner = {
		async preflight() {},
		async launch() {
			return "session";
		},
		async reconcile() {
			return "session";
		},
		async inspect(sessionId) {
			inspected++;
			return {
				sessionId,
				status: SessionStatus.Completed,
				failureReason: null,
				executions,
			};
		},
	};
	const config: CollaborationConfig = {
		taskId: task.id,
		channelId: "channel",
		participants,
		retryFailedStep: false,
		completeTaskOnSuccess: true,
		pollIntervalMs: 1,
		timeoutMs: 1000,
	};
	return {
		store,
		messages,
		gateway,
		riela,
		config,
		runner: new CollaborationRunner(gateway, riela, store),
		completed: () => completed,
		inspected: () => inspected,
		threadReads: () => threadReads,
	};
}
function session(overrides: Partial<RielaSessionView>): RielaSessionView {
	return {
		sessionId: "session",
		status: SessionStatus.Completed,
		failureReason: null,
		executions,
		...overrides,
	};
}

describe("collaboration refuses inconsistent external evidence", () => {
	test("failed session without diagnostic remains terminal when retry is disabled", async () => {
		const f = fixture();
		let launches = 0;
		f.riela.launch = async () => {
			launches++;
			return "session";
		};
		f.riela.inspect = async () =>
			session({
				status: SessionStatus.Failed,
				failureReason: null,
				executions: [],
			});
		await expect(f.runner.run(f.config)).rejects.toThrow(
			"Riela collaboration failed: unknown failure; use explicit retry",
		);
		expect(launches).toBe(1);
		expect(f.completed()).toBe(0);
		expect(f.messages).toHaveLength(1);
	});
	test("ambiguous accepted step cannot be published", async () => {
		const f = fixture();
		f.riela.inspect = async () =>
			session({ executions: [...executions, ...executions.slice(0, 1)] });
		await expect(f.runner.run(f.config)).rejects.toThrow("ambiguous completed");
		expect(f.messages).toHaveLength(1);
		expect(f.completed()).toBe(0);
	});
	test("missing task link fails before launch", async () => {
		const f = fixture();
		f.gateway.linkTask = async () => {};
		await expect(f.runner.run(f.config)).rejects.toThrow(
			"task-link postcondition",
		);
		expect(f.inspected()).toBe(0);
		expect(f.completed()).toBe(0);
	});
	test("immutable publication request cannot silently change", async () => {
		const f = fixture();
		await f.runner.run(f.config);
		const state = f.store.state;
		if (!state) throw Error("state missing");
		const request = state.turns["architect"];
		if (!request) throw Error("turn missing");
		f.store.state = {
			...state,
			turns: {
				...state.turns,
				architect: { ...request, content: "changed request" },
			},
		};
		await expect(f.runner.run(f.config)).rejects.toThrow(
			"immutable publication request",
		);
		expect(f.messages).toHaveLength(4);
		expect(f.completed()).toBe(1);
	});
	for (const duplicate of [false, true])
		test(`persisted reply ${duplicate ? "duplicated" : "missing"}`, async () => {
			const f = fixture();
			await f.runner.run(f.config);
			const reply = f.messages[1];
			if (!reply) throw Error("reply missing");
			if (duplicate) f.messages.push({ ...reply, id: "duplicate" });
			else f.messages.splice(1, 1);
			await expect(f.runner.run(f.config)).rejects.toThrow(
				duplicate
					? "Duplicate participant replies"
					: "Persisted reply is no longer observable",
			);
			expect(f.completed()).toBe(1);
		});
	test("invalid polling timing fails before effects", async () => {
		const f = fixture();
		await expect(f.runner.run({ ...f.config, timeoutMs: 0 })).rejects.toThrow(
			"positive integers",
		);
		expect(f.messages).toHaveLength(0);
	});
	test("wrong task identity fails before publication", async () => {
		const f = fixture();
		const getTask = f.gateway.getTask;
		f.gateway.getTask = async (id) => {
			const detail = await getTask(id);
			return { ...detail, task: { ...detail.task, id: "wrong" } };
		};
		await expect(f.runner.run(f.config)).rejects.toThrow(
			"different task identity",
		);
		expect(f.messages).toHaveLength(0);
	});
	test("changed authenticated authors cannot resume existing discussion", async () => {
		const f = fixture();
		await f.runner.run(f.config);
		const authors = await f.gateway.getExpectedAuthors();
		f.gateway.getExpectedAuthors = async () => ({
			...authors,
			coordinator: "different",
		});
		await expect(f.runner.run(f.config)).rejects.toThrow(
			"Authenticated authors differ",
		);
		expect(f.messages).toHaveLength(4);
		expect(f.completed()).toBe(1);
	});
	test("wrong session identity fails before turns", async () => {
		const f = fixture();
		f.riela.inspect = async () => session({ sessionId: "different" });
		await expect(f.runner.run(f.config)).rejects.toThrow(
			"different session identity",
		);
		expect(f.messages).toHaveLength(1);
	});
	test("terminal session with incomplete prefix cannot complete task", async () => {
		const f = fixture();
		f.riela.inspect = async () =>
			session({ executions: executions.slice(0, 1) });
		await expect(f.runner.run(f.config)).rejects.toThrow(
			"Not all configured turns",
		);
		expect(f.completed()).toBe(0);
	});
	test("unsolved final evidence is published but task stays open", async () => {
		const f = fixture();
		f.riela.inspect = async () =>
			session({
				executions: executions.map((e) =>
					e.stepId === "integrator"
						? {
								...e,
								acceptedPayload: {
									...record(e.acceptedPayload),
									solved: false,
									unresolved: ["unresolved blocker"],
								},
							}
						: e,
				),
			});
		await expect(f.runner.run(f.config)).rejects.toThrow(
			"Final decision is not solved",
		);
		expect(f.messages).toHaveLength(4);
		expect(f.completed()).toBe(0);
	});
	for (const duplicate of [false, true])
		test(`final canonical recheck detects ${duplicate ? "duplicate" : "missing"} reply`, async () => {
			const f = fixture();
			const getThread = f.gateway.getThread;
			f.gateway.getThread = async (id) => {
				const thread = await getThread(id);
				if (f.threadReads() !== 4) return thread;
				const reply = thread.replies[0];
				if (!reply) throw Error("reply missing");
				return {
					...thread,
					replies: duplicate
						? [...thread.replies, { ...reply, id: "duplicate" }]
						: thread.replies.slice(1),
				};
			};
			await expect(f.runner.run(f.config)).rejects.toThrow(
				duplicate
					? "Duplicate participant replies"
					: "Published reply is no longer observable",
			);
			expect(f.completed()).toBe(0);
		});
	test("nonterminal sessions poll until the bounded deadline", async () => {
		const f = fixture();
		const inspect = f.riela.inspect;
		f.riela.inspect = async (id) => ({
			...(await inspect(id)),
			status: SessionStatus.Running,
			executions: [],
		});
		await expect(f.runner.run({ ...f.config, timeoutMs: 20 })).rejects.toThrow(
			"before the deadline",
		);
		expect(f.inspected()).toBeGreaterThan(0);
		expect(f.messages).toHaveLength(1);
		expect(f.completed()).toBe(0);
	});
});
