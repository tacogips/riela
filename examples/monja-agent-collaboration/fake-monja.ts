import type { MonjaMessage, MonjaTask } from "./types";

export interface FakeMonjaCredentials {
	readonly [stepId: string]: string;
	readonly coordinator: string;
	readonly architect: string;
	readonly skeptic: string;
	readonly integrator: string;
}

export interface RecordedRequest {
	readonly method: string;
	readonly pathname: string;
	readonly token: string;
}

const json = (value: unknown, status = 200): Response =>
	Response.json(value, { status });

/** Deterministic in-memory subset of Monja used by the executable integration test. */
export class FakeMonjaServer {
	readonly task: MonjaTask = {
		id: "task-fixture",
		title: "Choose delivery semantics",
		description: "Select a resilient webhook delivery policy.",
		status: "open",
	};
	readonly channelId = "channel-fixture";
	readonly credentials: FakeMonjaCredentials = {
		coordinator: "fixture-coordinator-token",
		architect: "fixture-architect-token",
		skeptic: "fixture-skeptic-token",
		integrator: "fixture-integrator-token",
	};
	readonly requests: RecordedRequest[] = [];
	readonly messages: MonjaMessage[] = [];
	readonly links = new Set<string>();
	completionCalls = 0;
	#nextMessage = 1;
	readonly #receipts = new Map<
		string,
		{ request: string; message: MonjaMessage }
	>();
	loseNextMessageResponse = false;
	readonly #authors = new Map<string, string>([
		[this.credentials.coordinator, "fixture-coordinator-user"],
		[this.credentials.architect, "fixture-architect-user"],
		[this.credentials.skeptic, "fixture-skeptic-user"],
		[this.credentials.integrator, "fixture-integrator-user"],
	]);
	readonly #server: ReturnType<typeof Bun.serve>;

	constructor() {
		this.#server = Bun.serve({
			port: 0,
			hostname: "127.0.0.1",
			fetch: (request) => this.#fetch(request),
		});
	}

	get apiUrl(): string {
		return `http://127.0.0.1:${this.#server.port}/api/v1`;
	}

	addParticipant(stepId: string): void {
		const token = `fixture-${stepId}-token`;
		Object.assign(this.credentials, { [stepId]: token });
		this.#authors.set(token, `fixture-${stepId}-user`);
	}

	stop(): void {
		this.#server.stop(true);
	}

	async #fetch(request: Request): Promise<Response> {
		const url = new URL(request.url);
		const token =
			request.headers.get("authorization")?.replace(/^Bearer /, "") ?? "";
		this.requests.push({
			method: request.method,
			pathname: url.pathname,
			token,
		});
		const authorId = this.#authors.get(token);
		if (!authorId) return json({ error: "unauthorized" }, 401);
		const path = url.pathname.replace(/^\/api\/v1/, "");

		if (request.method === "GET" && path === "/auth/me") {
			return json({ user: { id: authorId } });
		}
		if (request.method === "GET" && path === `/tasks/${this.task.id}`) {
			return json({
				task: this.task,
				links: [...this.links].map((id) => ({
					message: this.messages.find((message) => message.id === id) ?? null,
				})),
			});
		}
		if (
			request.method === "POST" &&
			path === `/channels/${this.channelId}/messages`
		) {
			const body = (await request.json()) as Record<string, unknown>;
			if (typeof body["content"] !== "string")
				return json({ error: "invalid" }, 400);
			const parent = body["parentMessageId"];
			if (parent !== undefined && typeof parent !== "string")
				return json({ error: "invalid" }, 400);
			const key = body["idempotencyKey"];
			if (typeof key !== "string")
				return json({ error: "missing idempotencyKey" }, 400);
			const identity = JSON.stringify([authorId, this.channelId, key]);
			const requestIdentity = JSON.stringify([body["content"], parent ?? null]);
			const prior = this.#receipts.get(identity);
			if (prior)
				return prior.request === requestIdentity
					? json(prior.message)
					: json({ error: "conflict" }, 409);
			const message: MonjaMessage = {
				id: `message-${this.#nextMessage++}`,
				channelId: this.channelId,
				authorId,
				parentMessageId: typeof parent === "string" ? parent : null,
				content: body["content"],
			};
			this.messages.push(message);
			this.#receipts.set(identity, { request: requestIdentity, message });
			if (this.loseNextMessageResponse) {
				this.loseNextMessageResponse = false;
				return json({ error: "simulated response loss after commit" }, 503);
			}
			return json(message, 201);
		}
		if (request.method === "POST" && path === `/tasks/${this.task.id}/links`) {
			const body = (await request.json()) as Record<string, unknown>;
			if (typeof body["messageId"] !== "string")
				return json({ error: "invalid" }, 400);
			this.links.add(body["messageId"]);
			return json({ taskId: this.task.id, messageId: body["messageId"] }, 201);
		}
		const threadMatch = path.match(/^\/messages\/([^/]+)\/thread$/);
		if (request.method === "GET" && threadMatch?.[1]) {
			const root = this.messages.find(
				(message) => message.id === threadMatch[1],
			);
			if (!root) return json({ error: "not found" }, 404);
			return json({
				root,
				replies: this.messages.filter(
					(message) => message.parentMessageId === root.id,
				),
			});
		}
		if (request.method === "PATCH" && path === `/tasks/${this.task.id}`) {
			const body = (await request.json()) as Record<string, unknown>;
			if (body["status"] !== "done") return json({ error: "invalid" }, 400);
			Object.assign(this.task, { status: "done" as const });
			this.completionCalls += 1;
			return json({ task: this.task });
		}
		return json({ error: "not found" }, 404);
	}
}
