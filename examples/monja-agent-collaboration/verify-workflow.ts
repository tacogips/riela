import { strict as assert } from "node:assert";
import { mkdir, mkdtemp } from "node:fs/promises";
import { resolve } from "node:path";

import { rielaChildEnvironment } from "./riela";

const EXAMPLE_NAME = "monja-agent-collaboration";
const PERSONAS = ["architect", "skeptic", "integrator"] as const;

function object(value: unknown, label: string): Record<string, unknown> {
	assert.equal(typeof value, "object", `${label} must be an object`);
	assert.notEqual(value, null, `${label} must not be null`);
	assert.equal(Array.isArray(value), false, `${label} must not be an array`);
	return value as Record<string, unknown>;
}

function array(value: unknown, label: string): readonly unknown[] {
	assert.ok(Array.isArray(value), `${label} must be an array`);
	return value;
}

function assertNoConditionalSchemaKeywords(
	value: unknown,
	path = "$schema",
): void {
	if (Array.isArray(value)) {
		for (const [index, item] of value.entries()) {
			assertNoConditionalSchemaKeywords(item, `${path}[${index}]`);
		}
		return;
	}
	if (typeof value !== "object" || value === null) return;
	for (const [key, item] of Object.entries(value)) {
		assert.ok(
			!["if", "then", "else", "allOf", "oneOf", "anyOf", "not"].includes(key),
			`${path}.${key} must not use conditional schema composition`,
		);
		assertNoConditionalSchemaKeywords(item, `${path}.${key}`);
	}
}

async function commandJson(
	command: readonly string[],
	workingDirectory: string,
): Promise<Record<string, unknown>> {
	const child = Bun.spawn([...command], {
		cwd: workingDirectory,
		env: rielaChildEnvironment(),
		stdin: "ignore",
		stdout: "pipe",
		stderr: "pipe",
	});
	const [stdout, stderr, exitCode] = await Promise.all([
		new Response(child.stdout).text(),
		new Response(child.stderr).text(),
		child.exited,
	]);
	assert.equal(exitCode, 0, stderr.trim() || `command failed: ${command[1]}`);
	return object(JSON.parse(stdout), `output from ${command[1]}`);
}

/** Run the real Riela CLI and assert the stable workflow contract. */
export async function verifyWorkflow(
	repositoryRoot = resolve(import.meta.dir, "../.."),
	binary = resolve(repositoryRoot, ".build/debug/riela"),
): Promise<void> {
	const examplesRoot = resolve(repositoryRoot, "examples");
	const workflowRoot = resolve(examplesRoot, EXAMPLE_NAME);
	const temporaryRoot = resolve(repositoryRoot, "tmp");
	await mkdir(temporaryRoot, { recursive: true });
	const runRoot = await mkdtemp(
		resolve(temporaryRoot, "monja-collaboration-verify-"),
	);
	const variablesFile = resolve(runRoot, "variables.json");
	await Bun.write(
		variablesFile,
		JSON.stringify({
			workflowInput: {
				task: {
					id: "task-fixture",
					title: "Choose delivery semantics",
					description: "Select a resilient webhook delivery policy.",
					status: "open",
				},
			},
		}),
	);

	const common = [
		binary,
		"workflow",
		"--workflow-definition-dir",
		examplesRoot,
	];
	const validation = await commandJson(
		[
			binary,
			"workflow",
			"validate",
			EXAMPLE_NAME,
			"--workflow-definition-dir",
			examplesRoot,
		],
		repositoryRoot,
	);
	assert.equal(validation["valid"], true);
	assert.equal(validation["workflowId"], EXAMPLE_NAME);

	const inspection = await commandJson(
		[
			binary,
			"workflow",
			"inspect",
			EXAMPLE_NAME,
			"--workflow-definition-dir",
			examplesRoot,
			"--output",
			"json",
		],
		repositoryRoot,
	);
	assert.equal(inspection["workflowId"], EXAMPLE_NAME);
	assert.deepEqual(inspection["stepIds"], PERSONAS);
	assert.deepEqual(inspection["nodeRegistryIds"], PERSONAS);
	assert.deepEqual(object(inspection["counts"], "inspection.counts"), {
		crossWorkflowDispatches: 0,
		nodes: 3,
		steps: 3,
	});

	const result = await commandJson(
		[
			...common.slice(0, 2),
			"run",
			EXAMPLE_NAME,
			"--workflow-definition-dir",
			examplesRoot,
			"--mock-scenario",
			resolve(workflowRoot, "mock-scenario.json"),
			"--working-dir",
			repositoryRoot,
			"--variables-file",
			variablesFile,
			"--session-store",
			resolve(runRoot, "sessions"),
			"--artifact-root",
			resolve(runRoot, "artifacts"),
			"--no-supervisor-mode",
			"--output",
			"json",
		],
		repositoryRoot,
	);
	assert.equal(result["status"], "completed");
	assert.equal(result["exitCode"], 0);
	assert.equal(result["workflowId"], EXAMPLE_NAME);
	assert.equal(result["nodeExecutions"], 3);
	assert.equal(result["transitions"], 2);

	const session = object(result["session"], "result.session");
	const executions = array(session["executions"], "session.executions").map(
		(value, index) => object(value, `session.executions[${index}]`),
	);
	assert.deepEqual(
		executions.map((execution) => execution["stepId"]),
		PERSONAS,
	);
	assert.equal(new Set(executions.map((item) => item["executionId"])).size, 3);
	assert.ok(executions.every((item) => item["status"] === "completed"));

	const architect = object(
		object(executions[0]?.["acceptedOutput"], "architect.acceptedOutput")[
			"payload"
		],
		"architect.payload",
	);
	const skeptic = object(
		object(executions[1]?.["acceptedOutput"], "skeptic.acceptedOutput")[
			"payload"
		],
		"skeptic.payload",
	);
	assert.deepEqual(skeptic["priorTurns"], [
		{
			persona: architect["persona"],
			message: architect["message"],
			details: architect["details"],
		},
	]);
	const skepticInbox = object(
		object(
			object(executions[1]?.["inputSnapshot"], "skeptic.inputSnapshot")[
				"mergedVariables"
			],
			"skeptic.mergedVariables",
		)["_rielaInput"],
		"skeptic._rielaInput",
	);
	assert.deepEqual(
		object(skepticInbox["latest"], "skeptic.latest")["payload"],
		architect,
	);

	const integratorInbox = object(
		object(
			object(executions[2]?.["inputSnapshot"], "integrator.inputSnapshot")[
				"mergedVariables"
			],
			"integrator.mergedVariables",
		)["_rielaInput"],
		"integrator._rielaInput",
	);
	assert.deepEqual(
		object(integratorInbox["latest"], "integrator.latest")["payload"],
		skeptic,
	);
	assert.deepEqual(array(skeptic["priorTurns"], "skeptic.priorTurns")[0], {
		persona: architect["persona"],
		message: architect["message"],
		details: architect["details"],
	});

	const authoredWorkflow = object(
		await Bun.file(resolve(workflowRoot, "workflow.json")).json(),
		"workflow.json",
	);
	for (const [index, step] of array(
		authoredWorkflow["steps"],
		"workflow.steps",
	).entries()) {
		assert.equal(
			object(
				object(step, `workflow.steps[${index}]`)["sessionPolicy"],
				`workflow.steps[${index}].sessionPolicy`,
			)["mode"],
			"new",
		);
	}
	for (const persona of PERSONAS) {
		const node = object(
			await Bun.file(
				resolve(workflowRoot, "nodes", `node-${persona}.json`),
			).json(),
			`node-${persona}.json`,
		);
		assert.equal(node["agentSandbox"], "read-only");
		if (persona === "integrator") {
			const schema = object(
				object(node["output"], "integrator.output")["jsonSchema"],
				"integrator.output.jsonSchema",
			);
			assertNoConditionalSchemaKeywords(schema);
		}
	}
	const rootOutput = object(result["rootOutput"], "result.rootOutput");
	assert.equal(rootOutput["persona"], "integrator");
	assert.equal(rootOutput["solved"], true);
	assert.deepEqual(rootOutput["unresolved"], []);
}

if (import.meta.main) {
	await verifyWorkflow();
	console.log("monja-agent-collaboration verification passed");
}
