import { mkdir, mkdtemp } from "node:fs/promises";
import { resolve } from "node:path";
import { RielaExecutor } from "./executor";
import { fixtureProject, plan, task } from "./fixture";
import { type Run, RunStatus } from "./types";
import { workflow } from "./workflow";

const tests = Bun.spawn(
	[process.execPath, "test", resolve(import.meta.dir, "scheduler.test.ts")],
	{ stdout: "inherit", stderr: "inherit" },
);
if ((await tests.exited) !== 0)
	throw new Error("Deterministic integration tests failed");
const root = resolve(
	import.meta.dir,
	"../../tmp/monja-project-task-orchestrator-verification",
);
await mkdir(root, { recursive: true });
const directory = await mkdtemp(resolve(root, "run-"));
const t = task("fixture");
const p = plan(t);
const run: Run = {
	key: "fixture:g1",
	task: t,
	plan: p,
	generation: 1,
	payload: workflow(t, p, fixtureProject, 1),
	status: RunStatus.Running,
	sessionId: null,
	evidence: "",
	absorbed: [],
};
const executor = new RielaExecutor(
	directory,
	import.meta.dir,
	process.env["RIELA_BIN"] ?? "riela",
	resolve(import.meta.dir, "fixtures/mock-scenario.json"),
);
await executor.start(run);
const child = executor.processes.get(run.key);
if (!child) throw new Error("No Riela process handle");
await child.exited;
const evidence = await executor.inspect(run);
await Bun.write(
	resolve(directory, "verification.json"),
	JSON.stringify(evidence, null, 2),
);
if (evidence.status !== RunStatus.Succeeded)
	throw new Error(
		`Real Riela mock execution failed verification: ${JSON.stringify(evidence)}`,
	);
const cancelRun: Run = {
	...run,
	key: "cancel:g1",
	payload: {
		workflow: {
			workflowId: "monja-cancel-fixture",
			defaults: { maxLoopIterations: 1, nodeTimeoutMs: 120000 },
			entryStepId: "hold",
			nodes: [{ id: "hold", nodeFile: "nodes/hold.json" }],
			steps: [{ id: "hold", nodeId: "hold", role: "worker" }],
		},
		nodePayloads: {
			"nodes/hold.json": {
				id: "hold",
				nodeType: "sleep",
				sleep: { durationMs: 60000 },
				variables: {},
			},
		},
	},
};
const cancellation = new RielaExecutor(
	directory,
	import.meta.dir,
	process.env["RIELA_BIN"] ?? "riela",
);
await cancellation.start(cancelRun);
const deadline = Date.now() + 10000;
while (!(await cancellation.session(cancelRun.key))) {
	if (Date.now() > deadline)
		throw new Error("Cancellation fixture session did not start");
	await Bun.sleep(25);
}
if (!(await cancellation.pause(cancelRun)))
	throw new Error("Real Riela cancellation was not acknowledged");
const cancelled = await cancellation.session(cancelRun.key);
await Bun.write(
	resolve(directory, "cancellation.json"),
	JSON.stringify(cancelled, null, 2),
);
console.log(
	JSON.stringify(
		{
			fixture: "passed",
			realRielaTemporaryExecution: evidence,
			realRielaCancellation: {
				status: cancelled?.["status"],
				failureKind: cancelled?.["failureKind"],
			},
			evidenceDirectory: directory,
			liveMonja: "not tested",
			liveWrike: "not tested",
		},
		null,
		2,
	),
);
