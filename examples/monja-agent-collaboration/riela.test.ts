import { describe, expect, test } from "bun:test";
import { chmod, mkdtemp } from "node:fs/promises";
import { resolve } from "node:path";
import { CliRielaSessionRunner, rielaChildEnvironment } from "./riela";
import {
	type LaunchIntent,
	LaunchKind,
	type MonjaTask,
	SessionStatus,
} from "./types";

const intent = (): LaunchIntent => ({
	id: crypto.randomUUID(),
	kind: LaunchKind.Initial,
	sourceSessionId: null,
	stepId: null,
	sessionId: null,
});
const repositoryRoot = resolve(import.meta.dir, "../..");
const task: MonjaTask = {
	id: "task-fixture",
	title: "Fixture task",
	description: "Exercise the process boundary.",
	status: "open",
};

async function executable(source: string): Promise<string> {
	const root = await mkdtemp(resolve(repositoryRoot, "tmp/fake-riela-"));
	const path = resolve(root, "fake-riela.ts");
	await Bun.write(path, `#!/usr/bin/env bun\n${source}\n`);
	await chmod(path, 0o700);
	return path;
}

async function runnerFor(source: string, scenario: string | null = null) {
	const runtimeRoot = await mkdtemp(
		resolve(repositoryRoot, "tmp/riela-adapter-"),
	);
	return {
		runtimeRoot,
		runner: new CliRielaSessionRunner(
			await executable(source),
			import.meta.dir,
			repositoryRoot,
			runtimeRoot,
			scenario,
		),
	};
}

describe("CliRielaSessionRunner", () => {
	test("restart reconciles durable logs without executing a second model process", async () => {
		const { runner, runtimeRoot } = await runnerFor(
			'if (process.argv[2] === "session") console.log(JSON.stringify({sessionId:"fixture-session",status:"completed",executions:[]})); else console.log(JSON.stringify({sessionId:"fixture-session"}));',
		);
		const launch = intent();
		expect(await runner.launch(task, launch)).toBe("fixture-session");
		const restarted = new CliRielaSessionRunner(
			runner.binary,
			runner.workflowRoot,
			runner.workingDirectory,
			runtimeRoot,
		);
		expect(await restarted.reconcile(launch)).toBe("fixture-session");
		expect(await restarted.launch(task, launch)).toBe("fixture-session");
		expect(
			await Array.fromAsync(new Bun.Glob("launch-*.claim").scan(runtimeRoot)),
		).toHaveLength(1);
	});
	test("missing logs and ambiguous identities fail reconciliation without launching", async () => {
		const { runner, runtimeRoot } = await runnerFor(
			'throw new Error("must not run");',
		);
		const launch = intent();
		await expect(runner.reconcile(launch)).rejects.toThrow(
			"Indeterminate launch",
		);
		await Bun.write(
			resolve(runtimeRoot, `stdout-${launch.id}.jsonl`),
			'{"sessionId":"one"}\n{"sessionId":"two"}\n',
		);
		await expect(runner.reconcile(launch)).rejects.toThrow("ambiguous");
		await expect(
			runner.reconcile({ ...launch, id: "../escape" }),
		).rejects.toThrow("Invalid launch identity");
	});
	test("participant order mismatch is rejected before invoking the CLI", async () => {
		const { parseParticipants } = await import("./participants");
		const configured = parseParticipants(
			await Bun.file(resolve(import.meta.dir, "participants.json")).json(),
		);
		const { runner } = await runnerFor('throw new Error("must not run");');
		const actual = new CliRielaSessionRunner(
			runner.binary,
			resolve(import.meta.dir, ".."),
			repositoryRoot,
			runner.runtimeRoot,
		);
		await expect(actual.preflight([...configured].reverse())).rejects.toThrow(
			"Participant order",
		);
	});
	test("starts a process, ignores an incomplete line, and captures its session", async () => {
		const scenario = resolve(import.meta.dir, "mock-scenario.json");
		const { runner, runtimeRoot } = await runnerFor(
			'console.log("{"); console.log(JSON.stringify({sessionId:"fixture-session"}));',
			scenario,
		);
		expect(runner.sessionStore).toBe(resolve(runtimeRoot, "sessions"));
		expect(await runner.launch(task, intent())).toBe("fixture-session");
		const files = await Array.fromAsync(
			new Bun.Glob("variables-*.json").scan(runtimeRoot),
		);
		expect(files).toHaveLength(1);
		const variables = await Bun.file(
			resolve(runtimeRoot, files[0] ?? "missing"),
		).json();
		expect(variables).toEqual({ workflowInput: { task } });
	});

	test("reports a generic retained-log location when start exits without a session", async () => {
		const { runner, runtimeRoot } = await runnerFor('console.log("not-json");');
		await expect(runner.launch(task, intent())).rejects.toThrow(
			"Indeterminate launch",
		);
		try {
			await runner.launch(task, intent());
		} catch (error) {
			expect(error).toBeInstanceOf(Error);
			expect((error as Error).message).not.toContain(runtimeRoot);
		}
	});

	test("parses completed session executions and accepted payload variants", async () => {
		const session = {
			sessionId: "fixture-session",
			status: SessionStatus.Completed,
			failureReason: "retained diagnostic",
			executions: [
				{ stepId: "architect", status: "completed" },
				{ stepId: "skeptic", status: "completed", acceptedOutput: null },
				{
					stepId: "integrator",
					status: "completed",
					acceptedOutput: { payload: { solved: true } },
				},
			],
		};
		const { runner } = await runnerFor(
			`console.log(${JSON.stringify(JSON.stringify(session))});`,
		);
		expect(await runner.inspect("fixture-session")).toEqual({
			sessionId: "fixture-session",
			status: SessionStatus.Completed,
			failureReason: "retained diagnostic",
			executions: [
				{ stepId: "architect", status: "completed", acceptedPayload: null },
				{ stepId: "skeptic", status: "completed", acceptedPayload: null },
				{
					stepId: "integrator",
					status: "completed",
					acceptedPayload: { solved: true },
				},
			],
		});
	});

	test("rejects subprocess failure and invalid JSON", async () => {
		const failed = await runnerFor(
			'console.error("controlled failure"); process.exit(7);',
		);
		await expect(failed.runner.inspect("fixture-session")).rejects.toThrow(
			"Riela command failed (7): controlled failure",
		);
		const invalid = await runnerFor('console.log("not-json");');
		await expect(
			invalid.runner.inspect("fixture-session"),
		).rejects.toBeInstanceOf(SyntaxError);
	});

	test("rejects malformed session and execution shapes", async () => {
		const cases: readonly {
			readonly value: unknown;
			readonly message: string;
		}[] = [
			{ value: [], message: "session must be an object" },
			{
				value: { sessionId: "s", status: "completed", executions: {} },
				message: "session.executions must be an array",
			},
			{
				value: { sessionId: "s", status: "surprising", executions: [] },
				message: "Riela session status is invalid",
			},
			{
				value: { sessionId: "s", status: "completed", executions: [null] },
				message: "session.executions[0] must be an object",
			},
			{
				value: {
					sessionId: "s",
					status: "completed",
					executions: [
						{ stepId: "x", status: "completed", acceptedOutput: [] },
					],
				},
				message: "session.executions[0].acceptedOutput must be an object",
			},
		];
		for (const testCase of cases) {
			const { runner } = await runnerFor(
				`console.log(${JSON.stringify(JSON.stringify(testCase.value))});`,
			);
			await expect(runner.inspect("s")).rejects.toThrow(testCase.message);
		}
	});
});

test("child environment copies only present allowlisted keys", () => {
	expect(
		rielaChildEnvironment({
			PATH: "/fixture/bin",
			LANG: "C",
			MONJA_API_TOKEN: "excluded",
		}),
	).toEqual({ PATH: "/fixture/bin", LANG: "C" });
});
