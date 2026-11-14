import { describe, expect, test } from "bun:test";
import { strict as assert } from "node:assert";
import { cp, mkdir, mkdtemp } from "node:fs/promises";
import { resolve } from "node:path";
import { fourParticipantFixture } from "./extension-fixture";
import { FakeMonjaServer } from "./fake-monja";
import { HttpMonjaGateway } from "./monja";
import { rielaChildEnvironment } from "./riela";
import { parseState } from "./state";
import { record } from "./types";

const repositoryRoot = resolve(import.meta.dir, "../..");
const binary = resolve(repositoryRoot, ".build/debug/riela");
const scenario = resolve(import.meta.dir, "mock-scenario.json");

async function runExample(
	server: FakeMonjaServer,
	stateRoot: string,
	overrides: Readonly<Record<string, string>> = {},
): Promise<{
	readonly exitCode: number;
	readonly stdout: string;
	readonly stderr: string;
}> {
	const child = Bun.spawn(
		[
			"bun",
			resolve(import.meta.dir, "main.ts"),
			server.task.id,
			server.channelId,
		],
		{
			cwd: repositoryRoot,
			env: {
				...rielaChildEnvironment(),
				MONJA_API_URL: server.apiUrl,
				MONJA_API_TOKEN: server.credentials.coordinator,
				MONJA_ARCHITECT_TOKEN: server.credentials.architect,
				MONJA_SKEPTIC_TOKEN: server.credentials.skeptic,
				MONJA_INTEGRATOR_TOKEN: server.credentials.integrator,
				MONJA_COLLABORATION_STATE: stateRoot,
				MONJA_COLLABORATION_POLL_MS: "1",
				MONJA_COLLABORATION_TIMEOUT_MS: "30000",
				RIELA_BIN: binary,
				RIELA_MOCK_SCENARIO: scenario,
				...overrides,
			},
			stdin: "ignore",
			stdout: "pipe",
			stderr: "pipe",
		},
	);
	const [stdout, stderr, exitCode] = await Promise.all([
		new Response(child.stdout).text(),
		new Response(child.stderr).text(),
		child.exited,
	]);
	return { exitCode, stdout, stderr };
}

describe("executable collaboration against fake Monja", () => {
	test("runs four configured participants with unchanged runner source", async () => {
		const server = new FakeMonjaServer();
		server.addParticipant("operator");
		const stateRoot = await mkdtemp(
			resolve(repositoryRoot, "tmp/collaboration-four-"),
		);
		const workflowRoot = resolve(stateRoot, "workflows");
		const bundle = await fourParticipantFixture(workflowRoot);
		try {
			const result = await runExample(server, stateRoot, {
				RIELA_WORKFLOW_ROOT: workflowRoot,
				RIELA_MOCK_SCENARIO: resolve(bundle, "mock-scenario.json"),
				MONJA_OPERATOR_TOKEN: server.credentials["operator"] ?? "",
			});
			expect(result.stderr).toBe("");
			expect(result.exitCode).toBe(0);
			expect(server.messages.map((m) => m.authorId)).toEqual([
				"fixture-coordinator-user",
				"fixture-architect-user",
				"fixture-skeptic-user",
				"fixture-operator-user",
				"fixture-integrator-user",
			]);
			const state = parseState(
				await Bun.file(resolve(stateRoot, "state.json")).json(),
			);
			expect(state.participants).toHaveLength(4);
			expect(state.launches).toHaveLength(1);
			const restart = await runExample(server, stateRoot, {
				RIELA_WORKFLOW_ROOT: workflowRoot,
				RIELA_MOCK_SCENARIO: resolve(bundle, "mock-scenario.json"),
				MONJA_OPERATOR_TOKEN: server.credentials["operator"] ?? "",
			});
			expect(restart.exitCode).toBe(0);
			expect(server.messages).toHaveLength(5);
		} finally {
			server.stop();
		}
	}, 30_000);
	test("real CLI preserves accepted prefix after final failure and compatible prompt repair", async () => {
		const server = new FakeMonjaServer();
		const stateRoot = await mkdtemp(
			resolve(repositoryRoot, "tmp/collaboration-recovery-"),
		);
		const workflowRoot = resolve(stateRoot, "workflows");
		const bundle = resolve(workflowRoot, "monja-agent-collaboration");
		await mkdir(bundle, { recursive: true });
		for (const name of [
			"workflow.json",
			"participants.json",
			"nodes",
			"prompts",
		])
			await cp(resolve(import.meta.dir, name), resolve(bundle, name), {
				recursive: true,
			});
		const broken = record(await Bun.file(scenario).json());
		record(broken["integrator"])["payload"] = { persona: "integrator" };
		const failedScenario = resolve(stateRoot, "failed.json");
		await Bun.write(failedScenario, JSON.stringify(broken));
		try {
			const failed = await runExample(server, stateRoot, {
				RIELA_WORKFLOW_ROOT: workflowRoot,
				RIELA_MOCK_SCENARIO: failedScenario,
			});
			expect(failed.exitCode).toBe(1);
			expect(failed.stderr).toContain("explicit retry");
			expect(server.messages).toHaveLength(3);
			const before = parseState(
				await Bun.file(resolve(stateRoot, "state.json")).json(),
			);
			await Bun.write(
				resolve(bundle, "prompts/integrator.md"),
				(await Bun.file(resolve(bundle, "prompts/integrator.md")).text()) +
					"\nRepair the failed output using the native contract.\n",
			);
			const repaired = record(await Bun.file(scenario).json());
			record(repaired["architect"])["payload"] = {};
			record(repaired["skeptic"])["payload"] = {};
			const repairedScenario = resolve(stateRoot, "repaired.json");
			await Bun.write(repairedScenario, JSON.stringify(repaired));
			const recovered = await runExample(server, stateRoot, {
				RIELA_WORKFLOW_ROOT: workflowRoot,
				RIELA_MOCK_SCENARIO: repairedScenario,
				MONJA_COLLABORATION_RETRY_FAILED: "true",
			});
			expect(recovered.stderr).toBe("");
			expect(recovered.exitCode).toBe(0);
			const after = parseState(
				await Bun.file(resolve(stateRoot, "state.json")).json(),
			);
			expect(after.root).toEqual(before.root);
			expect(after.turns["architect"] ?? null).toEqual(
				before.turns["architect"] ?? null,
			);
			expect(after.turns["skeptic"] ?? null).toEqual(
				before.turns["skeptic"] ?? null,
			);
			expect(after.launches).toHaveLength(2);
			expect(after.launches[1]?.sourceSessionId).toBe(
				before.launches[0]?.sessionId ?? null,
			);
			expect(server.messages).toHaveLength(4);
		} finally {
			server.stop();
		}
	}, 30_000);
	test("publishes one linked ordered thread and reconciles an idempotent retry", async () => {
		const server = new FakeMonjaServer();
		const stateRoot = await mkdtemp(
			resolve(repositoryRoot, "tmp/monja-collaboration-integration-"),
		);
		try {
			const first = await runExample(server, stateRoot);
			expect(first.exitCode).toBe(0);
			expect(first.stderr).toBe("");
			const result = JSON.parse(first.stdout) as Record<string, unknown>;
			expect(result["completedTask"]).toBe(true);
			expect(server.task.status).toBe("done");
			expect(server.links.size).toBe(1);
			expect(server.messages).toHaveLength(4);
			const [root, ...replies] = server.messages;
			assert.ok(root);
			expect(root?.parentMessageId).toBeNull();
			expect(replies.map((reply) => reply.parentMessageId)).toEqual([
				root.id,
				root.id,
				root.id,
			]);
			expect(replies.map((reply) => reply.authorId)).toEqual([
				"fixture-architect-user",
				"fixture-skeptic-user",
				"fixture-integrator-user",
			]);
			expect(replies.map((reply) => reply.content.split("\n")[0])).toEqual([
				"[riela-collaboration:task-fixture:architect]",
				"[riela-collaboration:task-fixture:skeptic]",
				"[riela-collaboration:task-fixture:integrator]",
			]);
			const postTokens = server.requests
				.filter(
					(request) =>
						request.method === "POST" && request.pathname.endsWith("/messages"),
				)
				.map((request) => request.token);
			expect(postTokens).toEqual([
				server.credentials.coordinator,
				server.credentials.architect,
				server.credentials.skeptic,
				server.credentials.integrator,
			]);

			const retry = await runExample(server, stateRoot);
			expect(retry.exitCode).toBe(0);
			expect(server.links.size).toBe(1);
			expect(server.messages).toHaveLength(4);
		} finally {
			server.stop();
		}
	}, 30_000);

	test("auth adapter reports actual shared author identity for runner rejection", async () => {
		const server = new FakeMonjaServer();
		try {
			const gateway = new HttpMonjaGateway(server.apiUrl, {
				coordinator: server.credentials.coordinator,
				personas: {
					architect: server.credentials.coordinator,
					skeptic: server.credentials.coordinator,
					integrator: server.credentials.coordinator,
				},
			});
			const authors = await gateway.getExpectedAuthors();
			expect(
				new Set([authors.coordinator, ...Object.values(authors.personas)]).size,
			).toBe(1);
		} finally {
			server.stop();
		}
	});

	test("leaves the task open when Mira does not solve the task", async () => {
		const server = new FakeMonjaServer();
		const stateRoot = await mkdtemp(
			resolve(repositoryRoot, "tmp/monja-collaboration-unsolved-"),
		);
		const fixture = (await Bun.file(scenario).json()) as Record<
			string,
			unknown
		>;
		const integrator = fixture["integrator"] as Record<string, unknown>;
		const payload = integrator["payload"] as Record<string, unknown>;
		payload["solved"] = false;
		payload["unresolved"] = [
			"The receiver cannot yet guarantee atomic persistence.",
		];
		const unsolvedScenario = resolve(stateRoot, "unsolved-scenario.json");
		await Bun.write(unsolvedScenario, JSON.stringify(fixture));
		try {
			const result = await runExample(server, stateRoot, {
				RIELA_MOCK_SCENARIO: unsolvedScenario,
			});
			expect(result.exitCode).toBe(1);
			expect(result.stderr).toContain("task remains open");
			expect(server.task.status).toBe("open");
			expect(server.completionCalls).toBe(0);
		} finally {
			server.stop();
		}
	}, 30_000);
});

test("the Riela child environment excludes every Monja credential", () => {
	const environment = rielaChildEnvironment({
		PATH: "/fixture/bin",
		HOME: "/fixture/home",
		MONJA_API_TOKEN: "coordinator-secret",
		MONJA_ARCHITECT_TOKEN: "architect-secret",
		MONJA_SKEPTIC_TOKEN: "skeptic-secret",
		MONJA_INTEGRATOR_TOKEN: "integrator-secret",
		MONJA_SESSION_COOKIE: "session-secret",
	});
	assert.deepEqual(environment, {
		PATH: "/fixture/bin",
		HOME: "/fixture/home",
	});
	expect(Object.keys(environment).some((key) => key.startsWith("MONJA_"))).toBe(
		false,
	);
});
