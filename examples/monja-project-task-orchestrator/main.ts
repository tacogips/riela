import { mkdir } from "node:fs/promises";
import { resolve } from "node:path";
import { loadProject } from "./config";
import { RielaExecutor } from "./executor";
import { HttpProvider } from "./provider";
import { Scheduler } from "./scheduler";
import { Store } from "./store";

function required(key: string): string {
	const value = process.env[key];
	if (!value) throw new Error(`Set ${key} through your secret manager`);
	return value;
}
const config = process.argv[2];
if (!config)
	throw new Error(
		"Usage: bun main.ts project.json [--once]; start from the project working directory",
	);
const cwd = process.cwd();
const project = await loadProject(config, cwd);
const root = resolve(
	process.env["MONJA_ORCHESTRATOR_STATE"] ??
		"tmp/monja-project-task-orchestrator",
);
await mkdir(root, { recursive: true });
const store = new Store(resolve(root, "scheduler.sqlite"));
const executor = new RielaExecutor(
	resolve(root, "runs"),
	cwd,
	process.env["RIELA_BIN"] ?? "riela",
);
const provider = new HttpProvider(
	project,
	required("MONJA_API_URL"),
	required("MONJA_API_TOKEN"),
	process.env["WRIKE_API_URL"] ?? "https://www.wrike.com/api/v4",
	required("WRIKE_API_TOKEN"),
	store,
);
const scheduler = new Scheduler(
	project,
	store,
	provider,
	executor,
	executor.planner(project),
);
let stop = false;
process.on("SIGINT", () => {
	stop = true;
});
process.on("SIGTERM", () => {
	stop = true;
});
do {
	try {
		await scheduler.tick();
	} catch (error) {
		console.error(
			error instanceof Error
				? error.message
				: "Scheduler failed; durable state retained",
		);
		if (process.argv.includes("--once")) process.exitCode = 1;
	}
	if (process.argv.includes("--once") || stop) break;
	await Bun.sleep(5000);
} while (!stop);
store.db.close();
