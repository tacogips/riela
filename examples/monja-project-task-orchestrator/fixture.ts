import {
	type Executor,
	type Plan,
	type Project,
	type Run,
	RunStatus,
	record,
	string,
	type Task,
	TaskStatus,
} from "./types";

export const fixtureProject: Project = {
	projectId: "01K50000000000000000000001",
	channelId: "01K50000000000000000000002",
	directories: {
		api: "fixtures/project-a/api",
		site: "fixtures/project-a/site",
	},
	repositories: [],
	wrikeTasks: { a: "WRIEA", b: "WRIEB", c: "WRIEC" },
};
export function task(id = "a", description = "api"): Task {
	return {
		id,
		projectId: fixtureProject.projectId,
		title: `Task ${id}`,
		description,
		status: TaskStatus.Todo,
	};
}
export function plan(t: Task): Plan {
	return {
		goal: t.title,
		steps: ["Implement", "Check"],
		scopes: [t.description.includes("site") ? "site" : "api"],
		dependencies: [],
		mergeKey: t.description.includes("merge") ? "receipt" : "",
		verification: "Check requested artifact and test result",
	};
}

/** Real loopback HTTP services, including native Monja status/envelopes. */
export function fakeServices(initial: Task[]) {
	const tasks = structuredClone(initial);
	const log: string[] = [];
	let failures = 0;
	let ambiguousMirror = false;
	const mirrors: { id: string; description: string }[] = [];
	const server = Bun.serve({
		hostname: "127.0.0.1",
		port: 0,
		async fetch(request) {
			const url = new URL(request.url);
			const body =
				request.method === "GET"
					? {}
					: request.headers.get("content-type")?.includes("application/json")
						? record(await request.json())
						: Object.fromEntries(await request.formData());
			if (url.pathname.startsWith("/wrike/folders/")) {
				if (request.method === "GET") return Response.json({ data: mirrors });
				const mirror = {
					id: `CREATED${mirrors.length}`,
					description: string(body["description"]),
				};
				mirrors.push(mirror);
				log.push("wrike:created");
				if (ambiguousMirror) {
					ambiguousMirror = false;
					return new Response("lost acknowledgement", { status: 503 });
				}
				return Response.json({ data: [mirror] });
			}
			if (request.method === "GET" && url.pathname === "/tasks")
				return Response.json({
					items: tasks.map((t) => ({
						...t,
						status:
							t.status === TaskStatus.Todo
								? "open"
								: t.status === TaskStatus.Doing
									? "in_progress"
									: "done",
					})),
					nextCursor: null,
				});
			if (url.pathname.includes("/channels/")) {
				if (failures > 0) {
					failures--;
					return new Response("retry", { status: 503 });
				}
				log.push(`chat:${string(body["content"])}`);
			} else if (url.pathname.startsWith("/wrike/"))
				log.push(
					`wrike:${request.method}:${String(body["text"] ?? body["status"])}`,
				);
			else if (url.pathname.endsWith("/comments"))
				log.push(`plan:${url.pathname}:${String(body["body"])}`);
			else if (request.method === "PATCH") {
				const id = url.pathname.split("/").at(-1);
				const t = tasks.find((item) => item.id === id);
				if (!t) return new Response("missing", { status: 404 });
				if (body["status"]) {
					const native = string(body["status"]);
					if (!["open", "in_progress", "done"].includes(native))
						return new Response("invalid status", { status: 400 });
					t.status =
						native === "open"
							? TaskStatus.Todo
							: native === "in_progress"
								? TaskStatus.Doing
								: TaskStatus.Done;
					log.push(`status:${id}:${t.status}`);
				}
				if (body["description"]) {
					t.description = string(body["description"]);
					log.push(`description:${id}`);
				}
			}
			return Response.json({ ok: true });
		},
	});
	return {
		tasks,
		log,
		base: `http://127.0.0.1:${server.port}`,
		failNotifications(count: number) {
			failures = count;
		},
		ambiguousMirrorCreate() {
			ambiguousMirror = true;
		},
		mirrors,
		close() {
			server.stop(true);
		},
	};
}
export class FakeExecutor implements Executor {
	readonly starts: string[] = [];
	readonly state = new Map<string, RunStatus>();
	pauseAcknowledged = true;
	constructor(readonly log: string[]) {}
	async start(run: Run): Promise<void> {
		this.starts.push(run.key);
		this.log.push(`execute:${run.key}`);
		this.state.set(run.key, RunStatus.Running);
	}
	async inspect(run: Run) {
		return {
			status: this.state.get(run.key) ?? RunStatus.Unknown,
			sessionId: `session-${run.key}`,
			evidence: "work-0:completed; deterministic fixture check",
		};
	}
	async pause(run: Run): Promise<boolean> {
		this.log.push(`pause:${run.key}:${this.pauseAcknowledged}`);
		if (this.pauseAcknowledged) this.state.set(run.key, RunStatus.Paused);
		return this.pauseAcknowledged;
	}
}
