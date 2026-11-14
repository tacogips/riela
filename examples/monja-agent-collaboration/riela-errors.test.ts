import { describe, expect, test } from "bun:test";
import { chmod, mkdir, mkdtemp } from "node:fs/promises";
import { resolve } from "node:path";
import { parseParticipants } from "./participants";
import participantFixture from "./participants.json";
import { CliRielaSessionRunner } from "./riela";
import { type LaunchIntent, LaunchKind, record } from "./types";
import workflowFixture from "./workflow.json";

const repositoryRoot = resolve(import.meta.dir, "../..");
const participants = parseParticipants(participantFixture);
async function fixture(source: string, workflow: unknown = workflowFixture) {
	const root = await mkdtemp(resolve(repositoryRoot, "tmp/cli-validation-"));
	await mkdir(resolve(root, "monja-agent-collaboration"));
	await Bun.write(
		resolve(root, "monja-agent-collaboration/workflow.json"),
		JSON.stringify(workflow),
	);
	const executable = resolve(root, "fixture-cli.ts");
	await Bun.write(executable, `#!/usr/bin/env bun\n${source}\n`);
	await chmod(executable, 0o700);
	return {
		root,
		runner: new CliRielaSessionRunner(executable, root, repositoryRoot, root),
	};
}
describe("CLI adapter contract guards in the parent process", () => {
	for (const defect of [
		"reuse",
		"transition",
		"condition",
		"nonarray",
	] as const)
		test(`rejects workflow ${defect} before CLI execution`, async () => {
			const workflow = record(structuredClone(workflowFixture));
			const steps = workflow["steps"];
			if (!Array.isArray(steps)) throw Error("steps fixture missing");
			const first = record(steps[0]);
			if (defect === "reuse") first["sessionPolicy"] = { mode: "reuse" };
			else if (defect === "transition")
				first["transitions"] = [{ toStepId: "integrator" }];
			else if (defect === "condition")
				first["transitions"] = [{ toStepId: "skeptic", when: "sometimes" }];
			else first["transitions"] = {};
			const { runner } = await fixture(
				'throw Error("CLI must not be invoked");',
				workflow,
			);
			await expect(runner.preflight(participants)).rejects.toThrow(
				"exact sequential workflow with fresh sessions",
			);
		});
	test("native validation false is rejected after local graph validation", async () => {
		const { runner } = await fixture(
			"console.log(JSON.stringify({valid:false}));",
		);
		await expect(runner.preflight(participants)).rejects.toThrow(
			"Riela workflow validation failed",
		);
	});
	test("reconciliation verifies canonical session identity", async () => {
		const { root, runner } = await fixture(
			'console.log(JSON.stringify({sessionId:"different",status:"completed",executions:[]}));',
		);
		const intent: LaunchIntent = {
			id: crypto.randomUUID(),
			kind: LaunchKind.Initial,
			sourceSessionId: null,
			stepId: null,
			sessionId: null,
		};
		await Bun.write(
			resolve(root, `stdout-${intent.id}.jsonl`),
			JSON.stringify({ sessionId: "expected" }),
		);
		await expect(runner.reconcile(intent)).rejects.toThrow(
			"Reconciled session identity mismatch",
		);
	});
	test("accepted output without payload is explicitly absent", async () => {
		const { runner } = await fixture(
			'console.log(JSON.stringify({sessionId:"s",status:"completed",executions:[{stepId:"architect",status:"completed",acceptedOutput:{}}]}));',
		);
		expect(
			(await runner.inspect("s")).executions[0]?.acceptedPayload,
		).toBeNull();
	});
	test("recovery launch constructs native preserve-history command and ignores source log identity", async () => {
		const { root, runner } = await fixture(
			'await Bun.write(new URL("arguments.json",import.meta.url),JSON.stringify(process.argv.slice(2))); console.log(JSON.stringify({sessionId:"source"}));console.log(JSON.stringify({sessionId:"recovered"}));',
		);
		const intent: LaunchIntent = {
			id: crypto.randomUUID(),
			kind: LaunchKind.Recovery,
			sourceSessionId: "source",
			stepId: "integrator",
			sessionId: null,
		};
		expect(
			await runner.launch(
				{ id: "task", title: "Task", description: "", status: "open" },
				intent,
			),
		).toBe("recovered");
		const args: unknown = await Bun.file(
			resolve(root, "arguments.json"),
		).json();
		if (!Array.isArray(args)) throw Error("argument capture missing");
		expect(args.slice(0, 5)).toEqual([
			"session",
			"rerun",
			"source",
			"integrator",
			"--preserve-history",
		]);
		expect(args).not.toContain("--variables-file");
		expect(args).toContain("--session-store");
	});
});
