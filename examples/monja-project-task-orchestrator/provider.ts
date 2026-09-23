import type { Store } from "./store";
import {
	type Project,
	type Provider,
	type Run,
	record,
	string,
	type Task,
	TaskStatus,
} from "./types";

export class HttpProvider implements Provider {
	constructor(
		readonly project: Project,
		readonly monja: string,
		readonly token: string,
		readonly wrike: string,
		readonly wrikeToken: string,
		readonly store?: Store,
	) {
		for (const base of [monja, wrike]) {
			const url = new URL(base);
			if (
				url.protocol !== "https:" &&
				!(
					url.protocol === "http:" &&
					["localhost", "127.0.0.1"].includes(url.hostname)
				)
			)
				throw new Error("Provider requires HTTPS or loopback HTTP");
		}
	}
	private async wrikeRequest(
		path: string,
		body?: URLSearchParams,
	): Promise<Record<string, unknown>> {
		const response = await fetch(`${this.wrike.replace(/\/$/, "")}${path}`, {
			method: body ? "POST" : "GET",
			headers: {
				authorization: `Bearer ${this.wrikeToken}`,
				"content-type": "application/x-www-form-urlencoded",
			},
			...(body ? { body } : {}),
			redirect: "error",
			signal: AbortSignal.timeout(30000),
		});
		if (!response.ok)
			throw new Error(`Wrike mirror request failed (${response.status})`);
		return record(await response.json());
	}
	async ensureWrike(task: string): Promise<string> {
		const explicit = this.project.wrikeTasks[task];
		if (explicit) return explicit;
		const stored = this.store?.mirror(task);
		if (stored?.id) return stored.id;
		const folder = this.project.wrikeFolderId;
		if (!folder || !this.store)
			throw new Error(`Wrike mapping or folder/state missing for task ${task}`);
		const marker = `[monja:${this.project.projectId}:${task}]`;
		let next: string | null = null;
		const seen = new Set<string>();
		do {
			const query = new URLSearchParams({
				fields: JSON.stringify(["description"]),
			});
			if (next) query.set("nextPageToken", next);
			const page = await this.wrikeRequest(
				`/folders/${encodeURIComponent(folder)}/tasks?${query}`,
			);
			if (!Array.isArray(page["data"]))
				throw new Error("Invalid Wrike tasks page");
			const found = page["data"]
				.map(record)
				.find(
					(item) =>
						typeof item["description"] === "string" &&
						item["description"].includes(marker),
				);
			if (found) {
				const id = string(found["id"]);
				this.store.saveMirror(task, id);
				return id;
			}
			next =
				page["nextPageToken"] === undefined || page["nextPageToken"] === null
					? null
					: string(page["nextPageToken"]);
			if (next && seen.has(next))
				throw new Error("Repeated Wrike pagination token");
			if (next) seen.add(next);
		} while (next);
		if (stored)
			throw new Error(
				"Wrike create outcome unresolved; retaining reservation and reconciling on next tick",
			);
		this.store.saveMirror(task, null);
		const created = await this.wrikeRequest(
			`/folders/${encodeURIComponent(folder)}/tasks`,
			new URLSearchParams({
				title: `Monja task ${task}`,
				description: marker,
				status: "Active",
			}),
		);
		if (!Array.isArray(created["data"]) || created["data"].length !== 1)
			throw new Error("Invalid Wrike created task envelope");
		const id = string(record(created["data"][0])["id"]);
		this.store.saveMirror(task, id);
		return id;
	}
	private async request(
		path: string,
		body?: unknown,
		method = "POST",
	): Promise<unknown> {
		const response = await fetch(`${this.monja.replace(/\/$/, "")}${path}`, {
			method: body === undefined ? "GET" : method,
			headers: {
				authorization: `Bearer ${this.token}`,
				"content-type": "application/json",
			},
			...(body === undefined ? {} : { body: JSON.stringify(body) }),
			redirect: "error",
			signal: AbortSignal.timeout(30000),
		});
		if (!response.ok)
			throw new Error(
				`Monja ${body === undefined ? "GET" : method} ${path.split("?")[0]} failed (${response.status})`,
			);
		return response.json();
	}
	async tasks(): Promise<Task[]> {
		const result: Task[] = [];
		let cursor: string | null = null;
		const seen = new Set<string>();
		do {
			const query = new URLSearchParams({
				projectId: this.project.projectId,
				limit: "100",
			});
			if (cursor) query.set("before", cursor);
			const page = record(await this.request(`/tasks?${query}`));
			if (!Array.isArray(page["items"])) throw new Error("Invalid task page");
			for (const item of page["items"]) {
				const t = record(item);
				const rawStatus = string(t["status"]);
				const status =
					rawStatus === "open"
						? TaskStatus.Todo
						: rawStatus === "in_progress"
							? TaskStatus.Doing
							: rawStatus;
				if (!Object.values(TaskStatus).includes(status as TaskStatus)) continue;
				const task = {
					id: string(t["id"]),
					projectId: string(t["projectId"]),
					title: string(t["title"]),
					description:
						t["description"] === null ? "" : string(t["description"]),
					status: status as TaskStatus,
				};
				if (task.projectId !== this.project.projectId)
					throw new Error("Cross-project response rejected");
				result.push(task);
			}
			cursor = page["nextCursor"] === null ? null : string(page["nextCursor"]);
			if (cursor && seen.has(cursor))
				throw new Error("Repeated pagination cursor");
			if (cursor) seen.add(cursor);
		} while (cursor);
		return result;
	}
	async persist(run: Run): Promise<void> {
		if (run.checkpoints?.length) {
			const checkpoints = JSON.stringify(run.checkpoints);
			for (let offset = 0; offset < checkpoints.length; offset += 6000)
				await this.request(
					`/tasks/${encodeURIComponent(run.task.id)}/comments`,
					{
						body: `[${run.key}:checkpoints] offset=${offset}\n${checkpoints.slice(offset, offset + 6000)}`,
					},
				);
		}
		const description = `${run.task.description}\n\nRiela goal: ${run.plan.goal}\nGeneration: ${run.generation}\nSteps:\n${run.plan.steps.map((s, i) => `${i + 1}. ${s}`).join("\n")}\nAbsorbed tasks: ${run.absorbed.join(", ")}\nWorkflow persisted in task comments (${run.key}).`;
		if (description.length > 8000)
			throw new Error("Task decomposition exceeds Monja description limit");
		const workflow = JSON.stringify(run.payload);
		for (let offset = 0; offset < workflow.length; offset += 6000) {
			await this.request(`/tasks/${encodeURIComponent(run.task.id)}/comments`, {
				body: `[${run.key}:workflow:${offset}]\n${workflow.slice(offset, offset + 6000)}`,
			});
		}
		await this.request(
			`/tasks/${encodeURIComponent(run.task.id)}`,
			{ description },
			"PATCH",
		);
	}
	async status(task: string, status: TaskStatus): Promise<void> {
		await this.request(
			`/tasks/${encodeURIComponent(task)}`,
			{
				status:
					status === TaskStatus.Todo
						? "open"
						: status === TaskStatus.Doing
							? "in_progress"
							: "done",
			},
			"PATCH",
		);
	}
	async notify(
		key: string,
		task: string,
		message: string,
		wrike: boolean,
	): Promise<void> {
		// Provider POSTs have no idempotency API. Markers permit operator reconciliation;
		// outbox is at-least-once after an ambiguous network failure, never silently lost.
		await this.request(
			`/channels/${encodeURIComponent(this.project.channelId)}/messages`,
			{ content: `[${key}] ${message}` },
		);
		if (!wrike) return;
		const wrikeTask = await this.ensureWrike(task);
		const body = new URLSearchParams({ text: `[${key}] ${message}` });
		const response = await fetch(
			`${this.wrike.replace(/\/$/, "")}/tasks/${encodeURIComponent(wrikeTask)}/comments`,
			{
				method: "POST",
				headers: {
					authorization: `Bearer ${this.wrikeToken}`,
					"content-type": "application/x-www-form-urlencoded",
				},
				body,
				redirect: "error",
				signal: AbortSignal.timeout(30000),
			},
		);
		if (!response.ok)
			throw new Error(`Wrike notification failed (${response.status})`);
		if (key.endsWith(":completed")) {
			const updated = await fetch(
				`${this.wrike.replace(/\/$/, "")}/tasks/${encodeURIComponent(wrikeTask)}`,
				{
					method: "PUT",
					headers: {
						authorization: `Bearer ${this.wrikeToken}`,
						"content-type": "application/x-www-form-urlencoded",
					},
					body: new URLSearchParams({ status: "Completed" }),
					redirect: "error",
					signal: AbortSignal.timeout(30000),
				},
			);
			if (!updated.ok)
				throw new Error(`Wrike completion failed (${updated.status})`);
		}
	}
}
