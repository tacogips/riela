import { mkdir } from "node:fs/promises";
import { resolve } from "node:path";
import {
	type Payload,
	type Planner,
	type Project,
	parsePlan,
	type Run,
	RunStatus,
	record,
	string,
} from "./types";

/** Agent processes receive only the explicitly allowed execution environment. */
function agentEnvironment(): Record<string, string> {
	const env: Record<string, string> = {};
	for (const key of [
		"PATH",
		"HOME",
		"LANG",
		"TMPDIR",
		"CODEX_HOME",
		"OPENAI_API_KEY",
	]) {
		const value = process.env[key];
		if (value) env[key] = value;
	}
	return env;
}
export class RielaExecutor {
	readonly exitWrites = new Map<string, Promise<void>>();
	async persistExit(key: string, code: number): Promise<void> {
		await Bun.write(
			resolve(this.directory(key), "exit.json"),
			JSON.stringify({ code }),
		);
	}
	readonly processes = new Map<
		string,
		{
			pid: number;
			exitCode: number | null;
			exited: Promise<number>;
			kill(signal: "SIGTERM"): void;
		}
	>();
	constructor(
		readonly root: string,
		readonly cwd: string,
		readonly binary = "riela",
		readonly mockScenario: string | null = null,
	) {}
	private directory(key: string): string {
		if (!/^[A-Za-z0-9:_-]+$/.test(key)) throw new Error("Invalid run key");
		return resolve(this.root, key);
	}
	async launch(key: string, payload: Payload): Promise<void> {
		const directory = this.directory(key);
		await mkdir(directory, { recursive: true });
		const file = resolve(directory, "workflow.json");
		if (await Bun.file(file).exists())
			throw new Error(
				"Run generation already reserved; inspect existing evidence",
			);
		await Bun.write(file, JSON.stringify(payload));
		const args = [
			this.binary,
			"workflow",
			"run",
			file,
			"--working-dir",
			this.cwd,
			"--session-store",
			resolve(directory, "sessions"),
			"--artifact-root",
			resolve(directory, "artifacts"),
			"--output",
			"jsonl",
		];
		if (this.mockScenario) args.push("--mock-scenario", this.mockScenario);
		const child = Bun.spawn(args, {
			cwd: this.cwd,
			env: agentEnvironment(),
			stdin: "ignore",
			stdout: Bun.file(resolve(directory, "stdout.jsonl")),
			stderr: Bun.file(resolve(directory, "stderr.log")),
		});
		this.processes.set(key, child);
		await Bun.write(
			resolve(directory, "process.json"),
			JSON.stringify({ pid: child.pid }),
		);
		const exitWrite = child.exited
			.then(async (code) => {
				await this.persistExit(key, code);
			})
			.catch((error) => {
				console.error(
					"Failed to persist executor exit:",
					error instanceof Error ? error.message : "unknown",
				);
			});
		this.exitWrites.set(key, exitWrite);
	}
	async start(run: Run): Promise<void> {
		await this.launch(run.key, run.payload);
	}
	async livePid(key: string): Promise<number | null> {
		const owned = this.processes.get(key);
		if (owned) return owned.exitCode === null ? owned.pid : null;
		const file = Bun.file(resolve(this.directory(key), "process.json"));
		if (!(await file.exists())) return null;
		const pid = record(await file.json())["pid"];
		if (typeof pid !== "number" || !Number.isSafeInteger(pid) || pid < 1)
			throw new Error("Invalid persisted process identity");
		const probe = Bun.spawn(["ps", "-p", String(pid), "-o", "command="], {
			env: agentEnvironment(),
			stdout: "pipe",
			stderr: "pipe",
		});
		const [command, , code] = await Promise.all([
			new Response(probe.stdout).text(),
			new Response(probe.stderr).text(),
			probe.exited,
		]);
		if (code !== 0) return null;
		return command.includes(resolve(this.directory(key), "workflow.json")) &&
			command.includes("workflow run")
			? pid
			: null;
	}
	async session(key: string): Promise<Record<string, unknown> | null> {
		const directory = this.directory(key);
		const log = Bun.file(resolve(directory, "stdout.jsonl"));
		if (!(await log.exists())) return null;
		let sessionId: string | null = null;
		for (const line of (await log.text()).split("\n")) {
			if (!line.trim()) continue;
			try {
				const value = record(JSON.parse(line));
				if (typeof value["sessionId"] === "string") {
					sessionId = value["sessionId"];
					break;
				}
			} catch {
				/* An active process may have an incomplete final JSONL line. */
			}
		}
		if (!sessionId) return null;
		const child = Bun.spawn(
			[
				this.binary,
				"session",
				"status",
				sessionId,
				"--session-store",
				resolve(directory, "sessions"),
				"--output",
				"json",
			],
			{ env: agentEnvironment(), stdout: "pipe", stderr: "pipe" },
		);
		const [output, , code] = await Promise.all([
			new Response(child.stdout).text(),
			new Response(child.stderr).text(),
			child.exited,
		]);
		if (code !== 0)
			throw new Error(
				"Session inspection temporarily unavailable; retaining current run",
			);
		return record(JSON.parse(output));
	}
	async inspect(run: Run): Promise<{
		status: RunStatus;
		sessionId: string | null;
		evidence: string;
	}> {
		const session = await this.session(run.key);
		if (!session) {
			const exit = Bun.file(resolve(this.directory(run.key), "exit.json"));
			if (await exit.exists())
				return {
					status: RunStatus.Failed,
					sessionId: null,
					evidence: `CLI exited without a verifiable session: ${JSON.stringify(record(await exit.json()))}`,
				};
			return {
				status: (await this.livePid(run.key))
					? RunStatus.Running
					: RunStatus.Unknown,
				sessionId: null,
				evidence:
					"Session not yet observed; generation is reserved and will not be replayed",
			};
		}
		const sessionId = string(session["sessionId"]);
		const executions = Array.isArray(session["executions"])
			? session["executions"].map(record)
			: [];
		const evidence = executions
			.map((e) => `${e["stepId"]}:${e["status"]}`)
			.join(", ");
		if (session["status"] === "failed")
			return {
				status: RunStatus.Failed,
				sessionId,
				evidence: `${session["failureKind"]}: ${evidence}`,
			};
		if (session["status"] !== "completed") {
			const live = await this.livePid(run.key);
			return {
				status: live ? RunStatus.Running : RunStatus.Unknown,
				sessionId,
				evidence: `${evidence}; ${live ? "live process confirmed" : "process missing, manual reconciliation required"}`,
			};
		}
		const verify = executions.find((e) => e["stepId"] === "verify");
		const output = verify?.["acceptedOutput"]
			? record(record(verify["acceptedOutput"])["payload"])
			: {};
		const passed =
			output["verified"] === true &&
			typeof output["evidence"] === "string" &&
			output["evidence"].length > 0 &&
			executions.length === run.plan.steps.length + 1 &&
			executions.every((e) => e["status"] === "completed");
		return {
			status: passed ? RunStatus.Succeeded : RunStatus.Failed,
			sessionId,
			evidence: passed
				? `${evidence}; ${output["evidence"]}`
				: `Verification contract failed: ${evidence}`,
		};
	}
	async pause(run: Run): Promise<boolean> {
		const previous = await this.session(run.key);
		if (
			previous?.["status"] === "failed" &&
			previous["failureKind"] === "cancelled" &&
			!(await this.livePid(run.key))
		)
			return true;
		const pid = await this.livePid(run.key);
		if (!pid) return false;
		process.kill(pid, "SIGTERM");
		const deadline = Date.now() + 10000;
		while (await this.livePid(run.key)) {
			if (Date.now() >= deadline) return false;
			await Bun.sleep(50);
		}
		const session = await this.session(run.key);
		return (
			session?.["status"] === "failed" && session["failureKind"] === "cancelled"
		);
	}
	planner(project: Project): Planner {
		return async (task, previous) => {
			const key = `plan-${task.id}-${crypto.randomUUID()}`;
			await this.launch(key, {
				workflow: {
					workflowId: key,
					defaults: { nodeTimeoutMs: 600000, maxLoopIterations: 1 },
					entryStepId: "plan",
					nodes: [{ id: "plan", nodeFile: "nodes/plan.json" }],
					steps: [{ id: "plan", nodeId: "plan", role: "worker" }],
				},
				nodePayloads: {
					"nodes/plan.json": {
						id: "plan",
						executionBackend: "codex-agent",
						agentSandbox: "read-only",
						model: "gpt-5.6-luna",
						modelFreeze: true,
						variables: {},
						promptTemplate: `Analyze the task and return JSON only: {goal:string,steps:string[],scopes:string[],dependencies:string[],mergeKey:string,verification:string}. Scopes MUST be keys from directories. Include every directory that may be written. Dependencies are Monja task IDs. Use a stable semantic mergeKey only for tasks that should share a goal, else empty string. Do not implement or change files. Only codex-agent gpt-5.6-luna may be used. Task data: ${JSON.stringify({ task, previous, project })}`,
					},
				},
			});
			const child = this.processes.get(key);
			if (!child || (await child.exited) !== 0)
				throw new Error("Planner execution failed");
			const session = await this.session(key);
			if (
				session?.["status"] !== "completed" ||
				!Array.isArray(session["executions"])
			)
				throw new Error("Planner session incomplete");
			const execution = record(session["executions"][0]);
			return parsePlan(
				record(execution["acceptedOutput"])["payload"],
				Object.keys(project.directories),
			);
		};
	}
}
