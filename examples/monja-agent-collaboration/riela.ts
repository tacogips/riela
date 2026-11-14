import { mkdir, open } from "node:fs/promises";
import { resolve } from "node:path";
import {
	type LaunchIntent,
	LaunchKind,
	type MonjaTask,
	nonemptyString,
	type ParticipantConfig,
	type RielaSessionRunner,
	type RielaSessionView,
	type RielaStepExecution,
	record,
	SessionStatus,
} from "./types";

const EXECUTION_ENVIRONMENT_KEYS = [
	"PATH",
	"HOME",
	"LANG",
	"LC_ALL",
	"TMPDIR",
	"TERM",
	"CODEX_HOME",
	"OPENAI_API_KEY",
] as const;

/** Build the complete child environment; all Monja tokens are excluded by construction. */
export function rielaChildEnvironment(
	source: Readonly<Record<string, string | undefined>> = process.env,
): Record<string, string> {
	const environment: Record<string, string> = {};
	for (const key of EXECUTION_ENVIRONMENT_KEYS) {
		const value = source[key];
		if (value) environment[key] = value;
	}
	return environment;
}

function sessionStatus(value: unknown): SessionStatus {
	if (!Object.values(SessionStatus).includes(value as SessionStatus)) {
		throw new Error("Riela session status is invalid");
	}
	return value as SessionStatus;
}

function parseExecution(value: unknown, index: number): RielaStepExecution {
	const execution = record(value, `session.executions[${index}]`);
	const accepted = execution["acceptedOutput"];
	let acceptedPayload: unknown | null = null;
	if (accepted !== undefined && accepted !== null) {
		acceptedPayload =
			record(accepted, `session.executions[${index}].acceptedOutput`)[
				"payload"
			] ?? null;
	}
	return {
		stepId: nonemptyString(
			execution["stepId"],
			`session.executions[${index}].stepId`,
		),
		status: nonemptyString(
			execution["status"],
			`session.executions[${index}].status`,
		),
		acceptedPayload,
	};
}

function parseSession(value: unknown): RielaSessionView {
	const session = record(value, "session");
	if (!Array.isArray(session["executions"])) {
		throw new Error("session.executions must be an array");
	}
	return {
		sessionId: nonemptyString(session["sessionId"], "session.sessionId"),
		status: sessionStatus(session["status"]),
		failureReason:
			typeof session["failureReason"] === "string"
				? session["failureReason"]
				: null,
		executions: session["executions"].map(parseExecution),
	};
}

async function commandJson(
	args: readonly string[],
	environment: Readonly<Record<string, string>>,
	workingDirectory: string,
): Promise<unknown> {
	const child = Bun.spawn([...args], {
		cwd: workingDirectory,
		env: environment,
		stdin: "ignore",
		stdout: "pipe",
		stderr: "pipe",
	});
	const [stdout, stderr, code] = await Promise.all([
		new Response(child.stdout).text(),
		new Response(child.stderr).text(),
		child.exited,
	]);
	if (code !== 0) {
		throw new Error(
			`Riela command failed (${code}): ${stderr.trim().slice(0, 500)}`,
		);
	}
	return JSON.parse(stdout);
}

/** Process-backed Riela runner that inspects only canonical persisted sessions. */
export class CliRielaSessionRunner implements RielaSessionRunner {
	readonly #environment: Readonly<Record<string, string>>;

	constructor(
		readonly binary: string,
		readonly workflowRoot: string,
		readonly workingDirectory: string,
		readonly runtimeRoot: string,
		readonly mockScenario: string | null = null,
	) {
		this.#environment = rielaChildEnvironment();
	}

	get sessionStore(): string {
		return resolve(this.runtimeRoot, "sessions");
	}

	async preflight(participants: readonly ParticipantConfig[]): Promise<void> {
		const workflow = record(
			await Bun.file(
				resolve(this.workflowRoot, "monja-agent-collaboration/workflow.json"),
			).json(),
			"workflow",
		);
		if (
			!Array.isArray(workflow["steps"]) ||
			workflow["steps"].length !== participants.length ||
			workflow["entryStepId"] !== participants[0]?.stepId
		)
			throw new Error("Participant order must match the sequential workflow");
		for (const [i, value] of workflow["steps"].entries()) {
			const step = record(value, "workflow step");
			const transitions = step["transitions"] ?? [];
			const next = participants[i + 1];
			if (
				step["id"] !== participants[i]?.stepId ||
				record(step["sessionPolicy"], "session policy")["mode"] !== "new" ||
				!Array.isArray(transitions) ||
				transitions.length !== (next ? 1 : 0) ||
				(next &&
					(record(transitions[0])["toStepId"] !== next.stepId ||
						Object.keys(record(transitions[0])).some((k) => k !== "toStepId")))
			)
				throw new Error(
					"Participants require an exact sequential workflow with fresh sessions",
				);
		}
		const validation = record(
			await commandJson(
				[
					this.binary,
					"workflow",
					"validate",
					"monja-agent-collaboration",
					"--workflow-definition-dir",
					this.workflowRoot,
				],
				this.#environment,
				this.workingDirectory,
			),
			"validation",
		);
		if (validation["valid"] !== true)
			throw new Error("Riela workflow validation failed");
	}
	#paths(intent: LaunchIntent): {
		stdout: string;
		stderr: string;
		claim: string;
	} {
		if (!/^[a-f0-9-]{36}$/.test(intent.id))
			throw new Error("Invalid launch identity");
		return {
			stdout: resolve(this.runtimeRoot, `stdout-${intent.id}.jsonl`),
			stderr: resolve(this.runtimeRoot, `stderr-${intent.id}.log`),
			claim: resolve(this.runtimeRoot, `launch-${intent.id}.claim`),
		};
	}
	async #loggedSession(intent: LaunchIntent): Promise<string | null> {
		const file = Bun.file(this.#paths(intent).stdout);
		if (!(await file.exists())) return null;
		const ids = new Set<string>();
		for (const line of (await file.text()).split("\n")) {
			if (!line.trim()) continue;
			let event: Record<string, unknown>;
			try {
				event = record(JSON.parse(line));
			} catch {
				continue;
			} // Final line may be incomplete.
			if (
				typeof event["sessionId"] === "string" &&
				event["sessionId"] !== intent.sourceSessionId
			)
				ids.add(nonemptyString(event["sessionId"], "sessionId"));
		}
		if (ids.size > 1)
			throw new Error("Launch log has ambiguous session identities");
		return [...ids][0] ?? null;
	}
	async reconcile(intent: LaunchIntent): Promise<string> {
		const sessionId = await this.#loggedSession(intent);
		if (sessionId) {
			const canonical = await this.inspect(sessionId);
			if (canonical.sessionId !== sessionId)
				throw new Error("Reconciled session identity mismatch");
			return sessionId;
		}
		throw new Error(
			`Indeterminate launch ${intent.id}; inspect stdout-${intent.id}.jsonl, stderr-${intent.id}.log and the session store under the retained runtime directory. No additional model call was launched. Retry reconciliation after the original child exits; do not remove state to bypass this check.`,
		);
	}
	async launch(task: MonjaTask, intent: LaunchIntent): Promise<string> {
		await mkdir(this.runtimeRoot, { recursive: true });
		const paths = this.#paths(intent);
		let claim: Awaited<ReturnType<typeof open>>;
		try {
			claim = await open(paths.claim, "wx", 0o600);
		} catch {
			return this.reconcile(intent);
		}
		try {
			await claim.writeFile(JSON.stringify(intent));
			await claim.sync();
		} finally {
			await claim.close();
		}
		const variablesFile = resolve(
			this.runtimeRoot,
			`variables-${intent.id}.json`,
		);
		await Bun.write(variablesFile, JSON.stringify({ workflowInput: { task } }));
		const args =
			intent.kind === LaunchKind.Initial
				? [
						this.binary,
						"workflow",
						"run",
						"monja-agent-collaboration",
						"--variables-file",
						variablesFile,
					]
				: [
						this.binary,
						"session",
						"rerun",
						nonemptyString(intent.sourceSessionId, "recovery source"),
						nonemptyString(intent.stepId, "recovery target"),
						"--preserve-history",
					];
		args.push(
			"--workflow-definition-dir",
			this.workflowRoot,
			"--working-dir",
			this.workingDirectory,
			"--session-store",
			this.sessionStore,
			"--artifact-root",
			resolve(this.runtimeRoot, "artifacts"),
			"--output",
			"jsonl",
			"--no-supervisor-mode",
		);
		if (this.mockScenario) args.push("--mock-scenario", this.mockScenario);
		const child = Bun.spawn(args, {
			cwd: this.workingDirectory,
			env: this.#environment,
			stdin: "ignore",
			stdout: Bun.file(paths.stdout),
			stderr: Bun.file(paths.stderr),
		});
		const deadline = Date.now() + 30_000;
		while (Date.now() < deadline) {
			const sessionId = await this.#loggedSession(intent);
			if (sessionId) return sessionId;
			if (child.exitCode !== null) break;
			await Bun.sleep(50);
		}
		return this.reconcile(intent);
	}

	async inspect(sessionId: string): Promise<RielaSessionView> {
		return parseSession(
			await commandJson(
				[
					this.binary,
					"session",
					"status",
					sessionId,
					"--session-store",
					this.sessionStore,
					"--output",
					"json",
				],
				this.#environment,
				this.workingDirectory,
			),
		);
	}
}
