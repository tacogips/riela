import { afterEach, expect, spyOn, test } from "bun:test";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { resolve } from "node:path";
import { loadProject } from "./config";
import { RielaExecutor } from "./executor";
import {
	FakeExecutor,
	fakeServices,
	fixtureProject,
	plan,
	task,
} from "./fixture";
import { HttpProvider } from "./provider";
import { Scheduler } from "./scheduler";
import { Store } from "./store";
import { parsePlan, type Run, RunStatus, TaskStatus } from "./types";
import { workflow } from "./workflow";

const cleanups: (() => void)[] = [];
afterEach(() => {
	for (const cleanup of cleanups.splice(0)) cleanup();
});
function setup(tasks = [task()]) {
	const http = fakeServices(tasks);
	const store = new Store(":memory:");
	const executor = new FakeExecutor(http.log);
	const provider = new HttpProvider(
		fixtureProject,
		http.base,
		"fixture",
		`${http.base}/wrike`,
		"fixture",
	);
	const scheduler = new Scheduler(
		fixtureProject,
		store,
		provider,
		executor,
		async (t) => plan(t),
	);
	cleanups.push(() => {
		http.close();
		store.db.close();
	});
	return { http, store, executor, provider, scheduler };
}
test("native HTTP receipt, todo, persisted workflow, start, progress and verified completion order", async () => {
	const { http, scheduler, executor, store } = setup();
	await scheduler.tick();
	await scheduler.tick();
	executor.state.set("a:g1", RunStatus.Succeeded);
	await scheduler.tick();
	expect(http.tasks[0]?.status).toBe(TaskStatus.Done);
	const log = http.log;
	const receipt = log.findIndex((s) => s.includes("Task received"));
	const persisted = log.findIndex((s) => s.startsWith("plan:"));
	const doing = log.indexOf("status:a:doing");
	const started = log.findIndex((s) => s.includes(":started]"));
	const executed = log.indexOf("execute:a:g1");
	expect(receipt).toBeLessThan(persisted);
	expect(persisted).toBeLessThan(doing);
	expect(doing).toBeLessThan(started);
	expect(started).toBeLessThan(executed);
	expect(log.some((s) => s.includes("Progress"))).toBe(true);
	expect(log.some((s) => s === "wrike:PUT:Completed")).toBe(true);
	for (const node of Object.values(
		store.runs()[0]?.payload.nodePayloads ?? {},
	)) {
		expect(node["executionBackend"]).toBe("codex-agent");
		expect(node["model"]).toBe("gpt-5.6-luna");
	}
	await scheduler.tick();
	expect(executor.starts).toEqual(["a:g1"]);
});
test("duplicate event and notification outage retain a receipt and prevent premature execution", async () => {
	const { http, scheduler, store, executor } = setup();
	store.event("event1", "a");
	store.event("event1", "a");
	http.failNotifications(1);
	await expect(scheduler.tick()).rejects.toThrow("503");
	expect(executor.starts).toHaveLength(0);
	expect(store.pending()).toHaveLength(1);
	await scheduler.tick();
	expect(executor.starts).toEqual(["a:g1"]);
});
test("conflicting tasks wait, disjoint scopes run concurrently, dependencies wait", async () => {
	const { http, scheduler, executor } = setup([
		task(),
		task("b"),
		task("c", "site"),
	]);
	await scheduler.tick();
	expect(executor.starts).toEqual(["a:g1", "c:g1"]);
	executor.state.set("a:g1", RunStatus.Succeeded);
	await scheduler.tick();
	expect(executor.starts).toContain("b:g1");
	expect(http.tasks.find((t) => t.id === "a")?.status).toBe(TaskStatus.Done);
});
test("foreign doing task blocks unowned work", async () => {
	const doing = task("b", "site");
	doing.status = TaskStatus.Doing;
	const { scheduler, executor } = setup([task(), doing]);
	await scheduler.tick();
	expect(executor.starts).toHaveLength(0);
});
test("merge needs acknowledged cancellation then persists changed goal and starts new generation", async () => {
	const { http, scheduler, executor, store } = setup([task("a", "api merge")]);
	await scheduler.tick();
	http.tasks.push(task("b", "api merge"));
	executor.pauseAcknowledged = false;
	await scheduler.tick();
	expect(executor.starts).toEqual(["a:g1"]);
	executor.pauseAcknowledged = true;
	await scheduler.tick();
	expect(store.runs()[0]?.generation).toBe(2);
	await scheduler.tick();
	expect(executor.starts).toEqual(["a:g1", "a:g2"]);
	expect(store.runs()[0]?.task.description).toContain("Merged task b");
	expect(store.runs()[0]?.absorbed).toEqual(["b"]);
});
test("failed verification never marks done", async () => {
	const { http, scheduler, executor } = setup();
	await scheduler.tick();
	executor.state.set("a:g1", RunStatus.Failed);
	await scheduler.tick();
	expect(http.tasks[0]?.status).toBe(TaskStatus.Doing);
	expect(http.log.some((s) => s === "wrike:PUT:Completed")).toBe(false);
});
test("prelaunch persistence outage retries planned generation without losing task", async () => {
	const { scheduler, provider, executor, store } = setup();
	const persist = provider.persist.bind(provider);
	let fail = true;
	provider.persist = async (run) => {
		if (fail) {
			fail = false;
			throw new Error("persist outage");
		}
		await persist(run);
	};
	await expect(scheduler.tick()).rejects.toThrow("persist outage");
	expect(store.runs()[0]?.status).toBe(RunStatus.Planned);
	await scheduler.tick();
	expect(executor.starts).toEqual(["a:g1"]);
});
test("disk restart retains run dedup and probes unknown again", async () => {
	const tempRoot = resolve(
		import.meta.dir,
		"../../tmp/monja-project-task-orchestrator-tests",
	);
	await mkdir(tempRoot, { recursive: true });
	const directory = await mkdtemp(resolve(tempRoot, "state-"));
	const http = fakeServices([task()]);
	const executor = new FakeExecutor(http.log);
	const provider = new HttpProvider(
		fixtureProject,
		http.base,
		"fixture",
		`${http.base}/wrike`,
		"fixture",
	);
	let store = new Store(resolve(directory, "state.sqlite"));
	try {
		await new Scheduler(fixtureProject, store, provider, executor, async (t) =>
			plan(t),
		).tick();
		store.db.close();
		store = new Store(resolve(directory, "state.sqlite"));
		executor.state.delete("a:g1");
		const resumed = new Scheduler(
			fixtureProject,
			store,
			provider,
			executor,
			async (t) => plan(t),
		);
		await resumed.tick();
		expect(store.runs()[0]?.status).toBe(RunStatus.Unknown);
		executor.state.set("a:g1", RunStatus.Running);
		await resumed.tick();
		expect(store.runs()[0]?.status).toBe(RunStatus.Running);
		expect(executor.starts).toEqual(["a:g1"]);
	} finally {
		store.db.close();
		http.close();
		await rm(directory, { recursive: true });
	}
});

test("declared dependencies prevent execution until done", async () => {
	const { scheduler, executor, provider, store, http } = setup([task()]);
	const dependent = new Scheduler(
		fixtureProject,
		store,
		provider,
		executor,
		async (t) => ({ ...plan(t), dependencies: ["b"] }),
	);
	await dependent.tick();
	expect(executor.starts).toHaveLength(0);
	const dependency = task("b");
	dependency.status = TaskStatus.Done;
	http.tasks.push(dependency);
	await dependent.tick();
	expect(executor.starts).toEqual(["a:g1"]);
	await scheduler.flush();
});

test("paused merge survives planner failure and changes goal on retry", async () => {
	const { scheduler, executor, provider, store, http } = setup([
		task("a", "api merge"),
	]);
	await scheduler.tick();
	http.tasks.push(task("b", "api merge"));
	await scheduler.tick();
	let fail = true;
	const resumed = new Scheduler(
		fixtureProject,
		store,
		provider,
		executor,
		async (t, previous) => {
			if (previous && fail) {
				fail = false;
				throw new Error("planner outage");
			}
			return { ...plan(t), goal: previous ? "Combined receipt goal" : t.title };
		},
	);
	await expect(resumed.tick()).rejects.toThrow("planner outage");
	expect(store.runs()[0]?.pendingMerge?.id).toBe("b");
	await resumed.tick();
	expect(store.runs()[0]?.plan.goal).toBe("Combined receipt goal");
	expect(executor.starts).toEqual(["a:g1", "a:g2"]);
});

test("project scope validation rejects aliases and parent-child overlap", async () => {
	const root = resolve(
		import.meta.dir,
		"../../tmp/monja-project-task-orchestrator-tests",
	);
	await mkdir(root, { recursive: true });
	const directory = await mkdtemp(resolve(root, "config-"));
	try {
		const file = resolve(directory, "project.json");
		await Bun.write(
			file,
			JSON.stringify({
				...fixtureProject,
				directories: { api: directory, site: directory },
			}),
		);
		await expect(loadProject(file, directory)).rejects.toThrow("overlap");
		await mkdir(resolve(directory, "child"));
		await Bun.write(
			file,
			JSON.stringify({
				...fixtureProject,
				directories: { api: directory, site: resolve(directory, "child") },
			}),
		);
		await expect(loadProject(file, directory)).rejects.toThrow("overlap");
	} finally {
		await rm(directory, { recursive: true });
	}
});

test("executor recovers observed exit without session as failed, never replays", async () => {
	const { scheduler, store } = setup();
	await scheduler.tick();
	const run = store.runs()[0];
	if (!run) throw new Error("missing fixture run");
	const root = resolve(
		import.meta.dir,
		"../../tmp/monja-project-task-orchestrator-tests",
	);
	await mkdir(root, { recursive: true });
	const directory = await mkdtemp(resolve(root, "exit-"));
	try {
		await mkdir(resolve(directory, run.key));
		await Bun.write(
			resolve(directory, run.key, "exit.json"),
			JSON.stringify({ code: 1 }),
		);
		const executor = new RielaExecutor(directory, import.meta.dir);
		expect((await executor.inspect(run)).status).toBe(RunStatus.Failed);
		expect(await executor.pause(run)).toBe(false);
	} finally {
		await rm(directory, { recursive: true });
	}
});

test("new registration provisions durable Wrike mirror and reconciles ambiguous POST", async () => {
	const { http, store, executor } = setup();
	const project = {
		...fixtureProject,
		wrikeTasks: {},
		wrikeFolderId: "FOLDER",
	};
	const provider = new HttpProvider(
		project,
		http.base,
		"fixture",
		`${http.base}/wrike`,
		"fixture",
		store,
	);
	const scheduler = new Scheduler(
		project,
		store,
		provider,
		executor,
		async (t) => plan(t),
	);
	http.ambiguousMirrorCreate();
	await expect(scheduler.tick()).rejects.toThrow("503");
	expect(http.mirrors).toHaveLength(1);
	expect(executor.starts).toHaveLength(0);
	// A fresh provider obtains the created task via marker before creating again.
	const restarted = new HttpProvider(
		project,
		http.base,
		"fixture",
		`${http.base}/wrike`,
		"fixture",
		store,
	);
	await new Scheduler(project, store, restarted, executor, async (t) =>
		plan(t),
	).tick();
	expect(http.mirrors).toHaveLength(1);
	expect(store.mirror("a")?.id).toBe("CREATED0");
	expect(executor.starts).toEqual(["a:g1"]);
});

test("real Riela mock planner and executor preserve successful evidence across adapter restart", async () => {
	const root = resolve(
		import.meta.dir,
		"../../tmp/monja-project-task-orchestrator-tests",
	);
	await mkdir(root, { recursive: true });
	const directory = await mkdtemp(resolve(root, "cli-"));
	try {
		const binary = process.env["RIELA_BIN"] ?? "riela";
		const executor = new RielaExecutor(
			directory,
			import.meta.dir,
			binary,
			resolve(import.meta.dir, "fixtures/mock-scenario.json"),
		);
		const t = task("cli");
		const planned = await executor.planner(fixtureProject)(t, null);
		expect(planned.goal).toBe("Deliver receipt artifact");
		const run: Run = {
			key: "cli:g1",
			task: t,
			plan: planned,
			generation: 1,
			payload: workflow(t, planned, fixtureProject, 1),
			status: RunStatus.Running,
			sessionId: null,
			evidence: "",
			absorbed: [],
		};
		await executor.start(run);
		const child = executor.processes.get(run.key);
		if (!child) throw new Error("Missing real CLI process");
		await child.exited;
		expect((await executor.inspect(run)).status).toBe(RunStatus.Succeeded);
		const resumed = new RielaExecutor(directory, import.meta.dir, binary);
		expect((await resumed.inspect(run)).sessionId).toBe(
			"monja-cli-g1-session-1",
		);
		await expect(resumed.start(run)).rejects.toThrow("already reserved");
		expect(await resumed.livePid(run.key)).toBeNull();
		await expect(resumed.launch("../escape", run.payload)).rejects.toThrow(
			"Invalid run key",
		);
		await Bun.write(resolve(directory, run.key, "stdout.jsonl"), "{partial\n");
		expect(await resumed.session(run.key)).toBeNull();
	} finally {
		await rm(directory, { recursive: true });
	}
}, 60000);

test("trusted project configuration resolves repositories and validates planner write scopes", async () => {
	const project = await loadProject(
		resolve(import.meta.dir, "fixtures/project.json"),
		import.meta.dir,
	);
	expect(project.directories["api"]).toBe(
		resolve(import.meta.dir, "fixtures/project-a/api"),
	);
	expect(project.repositories.length).toBeGreaterThan(0);
	expect(() =>
		parsePlan(
			{ ...plan(task()), scopes: ["outside"] },
			Object.keys(project.directories),
		),
	).toThrow("unknown write scope");
	expect(() =>
		parsePlan({ ...plan(task()), steps: "invalid" }, ["api"]),
	).toThrow("string array");
	expect(() =>
		parsePlan({ ...plan(task()), verification: 5 }, ["api"]),
	).toThrow("Expected string");
	expect(() => parsePlan(null, ["api"])).toThrow("Expected JSON object");
});

test("terminal transition and notifications roll back together after interrupted enqueue", async () => {
	const { scheduler, store, executor, http } = setup();
	await scheduler.tick();
	executor.state.set("a:g1", RunStatus.Succeeded);
	const enqueue = store.enqueue.bind(store);
	let interrupt = true;
	store.enqueue = (id, task, message, wrike) => {
		enqueue(id, task, message, wrike);
		if (interrupt && id.endsWith(":completed")) {
			interrupt = false;
			throw new Error("simulated interruption after enqueue");
		}
	};
	await expect(scheduler.tick()).rejects.toThrow("simulated interruption");
	expect(store.runs()[0]?.status).toBe(RunStatus.Running);
	expect(store.pending().some((row) => row.id.endsWith(":completed"))).toBe(
		false,
	);
	await scheduler.tick();
	expect(store.runs()[0]?.status).toBe(RunStatus.Succeeded);
	expect(http.log.filter((row) => row === "wrike:PUT:Completed")).toHaveLength(
		1,
	);
});

test("crash after cancellation signal retains merge intent and checkpoint for restart", async () => {
	const { scheduler, store, executor, http, provider } = setup([
		task("a", "api merge"),
	]);
	await scheduler.tick();
	http.tasks.push(task("b", "api merge"));
	const pause = executor.pause.bind(executor);
	let interrupt = true;
	executor.pause = async (run) => {
		const acknowledged = await pause(run);
		if (interrupt) {
			interrupt = false;
			throw new Error("crash after signal");
		}
		return acknowledged;
	};
	await expect(scheduler.tick()).rejects.toThrow("crash after signal");
	expect(store.runs()[0]?.status).toBe(RunStatus.CancelRequested);
	expect(store.runs()[0]?.pendingMerge?.id).toBe("b");
	expect(executor.starts).toEqual(["a:g1"]);
	const restarted = new Scheduler(
		fixtureProject,
		store,
		provider,
		executor,
		async (t) => plan(t),
	);
	await restarted.tick();
	const merged = store.runs()[0];
	expect(merged?.checkpoints?.[0]).toMatchObject({
		runKey: "a:g1",
		generation: 1,
		sessionId: "session-a:g1",
		artifactReference: "a:g1/artifacts",
		cancellationAcknowledged: true,
	});
	expect(merged?.checkpoints?.[0]?.evidence).toContain("work-0:completed");
	expect(JSON.stringify(merged?.payload)).toContain("session-a:g1");
	expect(http.log.some((row) => row.includes(":checkpoints]"))).toBe(true);
	expect(executor.starts).toEqual(["a:g1", "a:g2"]);
});

test("dot-prefixed child directory is overlapping, not parent traversal", async () => {
	const root = resolve(
		import.meta.dir,
		"../../tmp/monja-project-task-orchestrator-tests",
	);
	await mkdir(root, { recursive: true });
	const directory = await mkdtemp(resolve(root, "dot-path-"));
	try {
		await mkdir(resolve(directory, "..cache"));
		const file = resolve(directory, "project.json");
		await Bun.write(
			file,
			JSON.stringify({
				...fixtureProject,
				directories: { api: directory, site: resolve(directory, "..cache") },
			}),
		);
		await expect(loadProject(file, directory)).rejects.toThrow("overlap");
	} finally {
		await rm(directory, { recursive: true });
	}
});

test("completion winning cancellation race releases incoming task for ordinary scheduling", async () => {
	const { scheduler, executor, http, store } = setup([task("a", "api merge")]);
	await scheduler.tick();
	http.tasks.push(task("b", "api merge"));
	executor.pauseAcknowledged = false;
	await scheduler.tick();
	executor.state.set("a:g1", RunStatus.Succeeded);
	await scheduler.tick();
	expect(store.runs().find((r) => r.task.id === "a")?.status).toBe(
		RunStatus.Succeeded,
	);
	expect(
		store.runs().find((r) => r.task.id === "a")?.pendingMerge,
	).toBeUndefined();
	expect(executor.starts).toEqual(["a:g1", "b:g1"]);
});

test("unrelated terminal failure during cancellation reports blocked merge and reserves incoming", async () => {
	const { scheduler, executor, http, store } = setup([task("a", "api merge")]);
	await scheduler.tick();
	http.tasks.push(task("b", "api merge"));
	executor.pauseAcknowledged = false;
	await scheduler.tick();
	executor.state.set("a:g1", RunStatus.Failed);
	await scheduler.tick();
	await scheduler.tick();
	expect(store.runs()[0]?.status).toBe(RunStatus.CancelRequested);
	expect(store.runs()[0]?.pendingMerge?.id).toBe("b");
	expect(executor.starts).toEqual(["a:g1"]);
	expect(
		http.log.filter(
			(row) => row.startsWith("chat:") && row.includes("Merge blocked"),
		),
	).toHaveLength(1);
});

test("expanded merge write scopes wait for existing parallel generation", async () => {
	const { scheduler, executor, http, store, provider } = setup([
		task("a", "api merge"),
		task("c", "site"),
	]);
	await scheduler.tick();
	http.tasks.push(task("b", "api merge"));
	await scheduler.tick();
	const expanded = new Scheduler(
		fixtureProject,
		store,
		provider,
		executor,
		async (t, previous) => ({
			...plan(t),
			scopes: previous ? ["api", "site"] : plan(t).scopes,
		}),
	);
	await expanded.tick();
	expect(executor.starts).toEqual(["a:g1", "c:g1"]);
	expect(store.runs().find((r) => r.task.id === "a")?.status).toBe(
		RunStatus.Paused,
	);
	executor.state.set("c:g1", RunStatus.Succeeded);
	await expanded.tick();
	expect(executor.starts).toContain("a:g2");
});

test("merged plan ignores its absorbed task dependency but waits for external dependency", async () => {
	const { scheduler, executor, http, store, provider } = setup([
		task("a", "api merge"),
	]);
	await scheduler.tick();
	http.tasks.push(task("b", "api merge"));
	await scheduler.tick();
	const dependent = new Scheduler(
		fixtureProject,
		store,
		provider,
		executor,
		async (t, previous) => ({
			...plan(t),
			dependencies: previous ? ["b", "d"] : [],
		}),
	);
	await dependent.tick();
	expect(executor.starts).toEqual(["a:g1"]);
	const d = task("d");
	d.status = TaskStatus.Done;
	http.tasks.push(d);
	await dependent.tick();
	expect(executor.starts).toEqual(["a:g1", "a:g2"]);
});

test("exit receipt write failure reports error while canonical session remains recoverable", async () => {
	class FailedExitReceipt extends RielaExecutor {
		override async persistExit(): Promise<void> {
			throw new Error("disk receipt unavailable");
		}
	}
	const root = resolve(
		import.meta.dir,
		"../../tmp/monja-project-task-orchestrator-tests",
	);
	await mkdir(root, { recursive: true });
	const directory = await mkdtemp(resolve(root, "receipt-failure-"));
	const logged = spyOn(console, "error").mockImplementation(() => {});
	try {
		const binary = process.env["RIELA_BIN"] ?? "riela";
		const executor = new FailedExitReceipt(
			directory,
			import.meta.dir,
			binary,
			resolve(import.meta.dir, "fixtures/mock-scenario.json"),
		);
		const t = task("receipt");
		const p = plan(t);
		const run: Run = {
			key: "receipt:g1",
			task: t,
			plan: p,
			generation: 1,
			payload: workflow(t, p, fixtureProject, 1),
			status: RunStatus.Running,
			sessionId: null,
			evidence: "",
			absorbed: [],
		};
		await executor.start(run);
		await executor.exitWrites.get(run.key);
		expect(logged).toHaveBeenCalledWith(
			"Failed to persist executor exit:",
			"disk receipt unavailable",
		);
		expect(
			await Bun.file(resolve(directory, run.key, "exit.json")).exists(),
		).toBe(false);
		const recovered = new RielaExecutor(directory, import.meta.dir, binary);
		expect((await recovered.inspect(run)).status).toBe(RunStatus.Succeeded);
	} finally {
		logged.mockRestore();
		await rm(directory, { recursive: true });
	}
}, 60000);
