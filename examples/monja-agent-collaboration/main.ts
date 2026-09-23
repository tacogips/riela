import { mkdir, realpath } from "node:fs/promises";
import { dirname, relative, resolve, sep } from "node:path";
import { HttpMonjaGateway } from "./monja";
import { parseParticipants } from "./participants";
import { CliRielaSessionRunner } from "./riela";
import { CollaborationRunner } from "./runner";
import { JsonCollaborationStateStore, withStateWriter } from "./state";
import type { CollaborationConfig, CollaborationResult } from "./types";

type Environment = Readonly<Record<string, string | undefined>>;

function requiredEnvironment(environment: Environment, key: string): string {
	const value = environment[key];
	if (!value) throw new Error(`Set ${key} through your secret manager`);
	return value;
}

function positiveEnvironment(
	environment: Environment,
	key: string,
	fallback: number,
): number {
	const raw = environment[key];
	if (raw === undefined) return fallback;
	const value = Number(raw);
	if (!Number.isSafeInteger(value) || value <= 0) {
		throw new Error(`${key} must be a positive integer`);
	}
	return value;
}

function resourceId(value: string | undefined, label: string): string {
	if (!value || !/^[A-Za-z0-9_-]+$/.test(value)) {
		throw new Error(`${label} must contain only letters, numbers, '_' or '-'`);
	}
	return value;
}

export async function confinedStateRoot(
	cwd: string,
	taskId: string,
	environment: Environment,
): Promise<string> {
	const temporaryRoot = resolve(cwd, "tmp");
	await mkdir(temporaryRoot, { recursive: true });
	const canonicalTemporaryRoot = await realpath(temporaryRoot);
	const requested = resolve(
		cwd,
		environment["MONJA_COLLABORATION_STATE"] ??
			`tmp/monja-agent-collaboration/${taskId}`,
	);
	const location = relative(canonicalTemporaryRoot, requested);
	if (location === ".." || location.startsWith(`..${sep}`)) {
		throw new Error(
			"MONJA_COLLABORATION_STATE must stay under repository tmp/",
		);
	}
	await mkdir(requested, { recursive: true });
	const canonical = await realpath(requested);
	const canonicalLocation = relative(canonicalTemporaryRoot, canonical);
	if (canonicalLocation === ".." || canonicalLocation.startsWith(`..${sep}`))
		throw new Error("State directory symlink escapes repository tmp/");
	return canonical;
}

/** Execute the CLI workflow with explicit inputs; no environment is passed through to model children. */
export async function runExampleMain(
	args: readonly string[],
	environment: Environment = process.env,
	cwd = process.cwd(),
): Promise<CollaborationResult> {
	const taskId = resourceId(args[0], "task-id");
	const channelId = resourceId(args[1], "channel-id");
	const workflowRoot = resolve(
		environment["RIELA_WORKFLOW_ROOT"] ?? dirname(import.meta.dir),
	);
	const participants = parseParticipants(
		await Bun.file(
			resolve(workflowRoot, "monja-agent-collaboration/participants.json"),
		).json(),
	);
	const personaTokens = Object.fromEntries(
		participants.map((p) => [
			p.stepId,
			requiredEnvironment(environment, p.tokenEnv),
		]),
	);
	const stateRoot = await confinedStateRoot(cwd, taskId, environment);
	const coordinatorToken = requiredEnvironment(environment, "MONJA_API_TOKEN");
	const config: CollaborationConfig = {
		taskId,
		channelId,
		participants,
		retryFailedStep: environment["MONJA_COLLABORATION_RETRY_FAILED"] === "true",
		completeTaskOnSuccess:
			environment["MONJA_COLLABORATION_COMPLETE_TASK"] !== "false",
		pollIntervalMs: positiveEnvironment(
			environment,
			"MONJA_COLLABORATION_POLL_MS",
			1_000,
		),
		timeoutMs: positiveEnvironment(
			environment,
			"MONJA_COLLABORATION_TIMEOUT_MS",
			30 * 60 * 1_000,
		),
	};
	const monja = new HttpMonjaGateway(
		requiredEnvironment(environment, "MONJA_API_URL"),
		{
			coordinator: coordinatorToken,
			personas: personaTokens,
		},
	);
	const riela = new CliRielaSessionRunner(
		environment["RIELA_BIN"] ?? "riela",
		workflowRoot,
		cwd,
		resolve(stateRoot, "riela"),
		environment["RIELA_MOCK_SCENARIO"] ?? null,
	);
	const runner = new CollaborationRunner(
		monja,
		riela,
		new JsonCollaborationStateStore(resolve(stateRoot, "state.json")),
	);

	return withStateWriter(resolve(stateRoot, "writer.sqlite"), () =>
		runner.run(config),
	);
}

if (import.meta.main) {
	try {
		console.log(JSON.stringify(await runExampleMain(process.argv.slice(2))));
	} catch (error) {
		console.error(
			error instanceof Error
				? error.message
				: "Collaboration failed; durable state was retained",
		);
		process.exitCode = 1;
	}
}
