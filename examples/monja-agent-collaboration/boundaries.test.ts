import { expect, test } from "bun:test";
import { mkdtemp, symlink } from "node:fs/promises";
import { resolve } from "node:path";
import { FakeMonjaServer } from "./fake-monja";
import { confinedStateRoot, runExampleMain } from "./main";
import { parseParticipants } from "./participants";
import fixture from "./participants.json";
import { parsePersonaOutput } from "./persona-output";
import { rielaChildEnvironment } from "./riela";
import { withStateWriter } from "./state";

const root = resolve(import.meta.dir, "../..");
const participants = parseParticipants(fixture);

test("actual CLI reports missing arguments with exit one", async () => {
	const child = Bun.spawn(
		[process.execPath, resolve(import.meta.dir, "main.ts")],
		{
			cwd: root,
			env: { LANG: "C" },
			stdin: "ignore",
			stdout: "pipe",
			stderr: "pipe",
		},
	);
	const [stdout, stderr, code] = await Promise.all([
		new Response(child.stdout).text(),
		new Response(child.stderr).text(),
		child.exited,
	]);
	expect(code).toBe(1);
	expect(stdout).toBe("");
	expect(stderr).toBe(
		"task-id must contain only letters, numbers, '_' or '-'\n",
	);
});

test("participant parser rejects malformed identity, credential names, final ownership and cardinality", () => {
	for (const value of [
		null,
		[],
		[fixture[0]],
		[...fixture, fixture[0]],
		fixture.map((p) => ({ ...p, finalDecision: false })),
		fixture.map((p) => ({ ...p, tokenEnv: "OPENAI_API_KEY" })),
		fixture.map((p) => ({ ...p, tokenEnv: "MONJA_API_TOKEN" })),
		fixture.map((p) => ({ ...p, stepId: "root" })),
		fixture.map((p) => ({ ...p, stepId: "../bad" })),
		fixture.map((p) => ({ ...p, unexpected: true })),
		fixture.map((p) => ({ ...p, finalDecision: "yes" })),
	]) {
		expect(() => parseParticipants(value)).toThrow();
	}
	expect(
		parseParticipants(
			fixture.map((p, i) => (i === 0 ? { ...p, stepId: "constructor" } : p)),
		)[0]?.stepId,
	).toBe("constructor");
});

test("generic final envelope rejects dishonest success and missing evidence", () => {
	const final = participants.at(-1);
	if (!final) throw new Error("Missing final fixture");
	const base = {
		persona: final.stepId,
		message: "decision",
		details: {},
		priorTurns: [],
		solved: true,
		unresolved: [],
		acceptanceCriteria: ["checked"],
	};
	for (const extra of [
		{ solved: "true" },
		{ unresolved: ["blocker"] },
		{ acceptanceCriteria: [] },
		{ acceptanceCriteria: [0] },
		{ details: null },
		{ priorTurns: [{}] },
		{ message: "" },
		{ persona: "other" },
	])
		expect(() =>
			parsePersonaOutput(final, { ...base, ...extra }, []),
		).toThrow();
	expect(parsePersonaOutput(final, base, []).solved).toBe(true);
});

test("writer lock excludes competitors and releases on thrown operation", async () => {
	const directory = await mkdtemp(resolve(root, "tmp/collaboration-lock-"));
	const path = resolve(directory, "writer.sqlite");
	await expect(
		withStateWriter(path, async () => {
			await expect(withStateWriter(path, async () => null)).rejects.toThrow(
				"Another collaboration runner",
			);
			throw new Error("failure");
		}),
	).rejects.toThrow("failure");
	expect(await withStateWriter(path, async () => "released")).toBe("released");
});

test("writer lock is released when its owning process crashes", async () => {
	const directory = await mkdtemp(
		resolve(root, "tmp/collaboration-lock-crash-"),
	);
	const path = resolve(directory, "writer.sqlite");
	const code = `import {withStateWriter} from ${JSON.stringify(resolve(import.meta.dir, "state.ts"))}; await withStateWriter(${JSON.stringify(path)},async()=>{console.log("locked");await Bun.sleep(30000)});`;
	const child = Bun.spawn([process.execPath, "-e", code], {
		cwd: root,
		env: rielaChildEnvironment(),
		stdout: "pipe",
		stderr: "pipe",
	});
	const reader = child.stdout.getReader();
	const ready = await reader.read();
	expect(new TextDecoder().decode(ready.value)).toContain("locked");
	child.kill("SIGKILL");
	await child.exited;
	expect(await withStateWriter(path, async () => "recovered")).toBe(
		"recovered",
	);
});

test("state confinement rejects traversal and symlink escape", async () => {
	const directory = await mkdtemp(
		resolve(root, "tmp/collaboration-confinement-"),
	);
	await expect(
		confinedStateRoot(root, "t", { MONJA_COLLABORATION_STATE: "../outside" }),
	).rejects.toThrow("under repository tmp");
	await symlink(resolve(root, "examples"), resolve(directory, "outside"));
	await expect(
		confinedStateRoot(root, "t", {
			MONJA_COLLABORATION_STATE: resolve(directory, "outside"),
		}),
	).rejects.toThrow("symlink escapes");
});

test("entry rejects missing identity/credentials and bad timeout before network", async () => {
	await expect(runExampleMain([], {}, root)).rejects.toThrow("task-id");
	await expect(runExampleMain(["t"], {}, root)).rejects.toThrow("channel-id");
	await expect(runExampleMain(["t", "c"], {}, root)).rejects.toThrow(
		"MONJA_ARCHITECT_TOKEN",
	);
	const environment = {
		MONJA_ARCHITECT_TOKEN: "fixture-a",
		MONJA_SKEPTIC_TOKEN: "fixture-b",
		MONJA_INTEGRATOR_TOKEN: "fixture-c",
		MONJA_API_TOKEN: "fixture-coordinator",
		MONJA_COLLABORATION_POLL_MS: "zero",
	};
	await expect(runExampleMain(["t", "c"], environment, root)).rejects.toThrow(
		"positive integer",
	);
});

test("importable entry executes real native CLI with fixture credentials and no process env mutation", async () => {
	const server = new FakeMonjaServer();
	const directory = await mkdtemp(resolve(root, "tmp/collaboration-entry-"));
	try {
		const result = await runExampleMain(
			[server.task.id, server.channelId],
			{
				MONJA_API_URL: server.apiUrl,
				MONJA_API_TOKEN: server.credentials.coordinator,
				MONJA_ARCHITECT_TOKEN: server.credentials.architect,
				MONJA_SKEPTIC_TOKEN: server.credentials.skeptic,
				MONJA_INTEGRATOR_TOKEN: server.credentials.integrator,
				MONJA_COLLABORATION_STATE: directory,
				MONJA_COLLABORATION_COMPLETE_TASK: "false",
				MONJA_COLLABORATION_TIMEOUT_MS: "30000",
				RIELA_BIN: resolve(root, ".build/debug/riela"),
				RIELA_MOCK_SCENARIO: resolve(import.meta.dir, "mock-scenario.json"),
			},
			root,
		);
		expect(result.completedTask).toBe(false);
		expect(server.task.status).toBe("open");
		expect(server.messages).toHaveLength(4);
	} finally {
		server.stop();
	}
}, 30000);
