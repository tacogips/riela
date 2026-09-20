import {
	type MonjaAuthorMap,
	type MonjaGateway,
	type MonjaMessage,
	type MonjaTask,
	type MonjaThread,
	nonemptyString,
	record,
} from "./types";

export interface MonjaTokens {
	readonly coordinator: string;
	readonly personas: Readonly<Record<string, string>>;
}

function safeBaseUrl(value: string): string {
	const url = new URL(value);
	const loopback = ["localhost", "127.0.0.1", "::1"].includes(url.hostname);
	if (url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) {
		throw new Error("Monja requires HTTPS or loopback HTTP");
	}
	url.pathname = url.pathname.replace(/\/$/, "");
	return url.toString().replace(/\/$/, "");
}

function parseMessage(value: unknown, label: string): MonjaMessage {
	const message = record(value, label);
	const parent = message["parentMessageId"];
	if (parent !== null && typeof parent !== "string") {
		throw new Error(`${label}.parentMessageId must be a string or null`);
	}
	return {
		id: nonemptyString(message["id"], `${label}.id`),
		channelId: nonemptyString(message["channelId"], `${label}.channelId`),
		authorId: nonemptyString(message["authorId"], `${label}.authorId`),
		parentMessageId: parent,
		content: nonemptyString(message["content"], `${label}.content`),
	};
}

function parseTask(value: unknown): MonjaTask {
	const task = record(value, "task");
	const status = task["status"];
	if (status !== "open" && status !== "in_progress" && status !== "done") {
		throw new Error("task.status is invalid");
	}
	return {
		id: nonemptyString(task["id"], "task.id"),
		title: nonemptyString(task["title"], "task.title"),
		description:
			typeof task["description"] === "string" ? task["description"] : "",
		status,
	};
}

/** Minimal REST adapter. Coordinator and persona credentials never leave this boundary. */
export class HttpMonjaGateway implements MonjaGateway {
	readonly #baseUrl: string;

	constructor(
		baseUrl: string,
		readonly tokens: MonjaTokens,
		readonly requestTimeoutMs = 30_000,
	) {
		this.#baseUrl = safeBaseUrl(baseUrl);
	}

	async #request(
		token: string,
		method: "GET" | "POST" | "PATCH",
		path: string,
		body?: unknown,
	): Promise<unknown> {
		const response = await fetch(`${this.#baseUrl}${path}`, {
			method,
			headers: {
				authorization: `Bearer ${token}`,
				"content-type": "application/json",
			},
			...(body === undefined ? {} : { body: JSON.stringify(body) }),
			redirect: "error",
			signal: AbortSignal.timeout(this.requestTimeoutMs),
		});
		if (!response.ok) {
			throw new Error(
				`Monja ${method} ${path.split("?")[0]} failed (${response.status})`,
			);
		}
		return response.status === 204 ? null : response.json();
	}

	async #author(token: string): Promise<string> {
		const principal = record(
			await this.#request(token, "GET", "/auth/me"),
			"authenticated principal",
		);
		return nonemptyString(
			record(principal["user"], "authenticated principal.user")["id"],
			"authenticated principal.user.id",
		);
	}

	async getExpectedAuthors(): Promise<MonjaAuthorMap> {
		const coordinator = await this.#author(this.tokens.coordinator);
		const entries = await Promise.all(
			Object.entries(this.tokens.personas).map(
				async ([id, token]) => [id, await this.#author(token)] as const,
			),
		);
		return {
			coordinator,
			personas: Object.fromEntries(entries),
		};
	}

	async getTask(taskId: string): Promise<{
		readonly task: MonjaTask;
		readonly linkedMessages: readonly MonjaMessage[];
	}> {
		const value = record(
			await this.#request(
				this.tokens.coordinator,
				"GET",
				`/tasks/${encodeURIComponent(taskId)}`,
			),
			"task detail",
		);
		if (!Array.isArray(value["links"])) {
			throw new Error("task detail.links must be an array");
		}
		const visibleLinks = value["links"].flatMap((item, index) => {
			const message = record(item, `task detail.links[${index}]`)["message"];
			if (message === null) return [];
			return [record(message, `task detail.links[${index}].message`)];
		});
		const linkedMessages = await Promise.all(
			visibleLinks.map(async (visible, index) => {
				const label = `task detail visible link[${index}]`;
				const messageId = nonemptyString(visible["id"], `${label}.id`);
				const thread = await this.getThread(messageId);
				const canonical =
					thread.root.id === messageId
						? thread.root
						: thread.replies.find((reply) => reply.id === messageId);
				if (!canonical) {
					throw new Error(`${label} is absent from its canonical thread`);
				}
				if (
					canonical.channelId !==
						nonemptyString(visible["channelId"], `${label}.channelId`) ||
					canonical.authorId !==
						nonemptyString(visible["authorId"], `${label}.authorId`) ||
					canonical.content !==
						nonemptyString(visible["content"], `${label}.content`)
				) {
					throw new Error(`${label} disagrees with its canonical thread`);
				}
				return canonical;
			}),
		);
		return { task: parseTask(value["task"]), linkedMessages };
	}

	async createRoot(
		channelId: string,
		content: string,
		idempotencyKey: string,
	): Promise<MonjaMessage> {
		return parseMessage(
			await this.#request(
				this.tokens.coordinator,
				"POST",
				`/channels/${encodeURIComponent(channelId)}/messages`,
				{ content, idempotencyKey },
			),
			"created root",
		);
	}

	async postTurn(
		persona: string,
		channelId: string,
		rootId: string,
		content: string,
		idempotencyKey: string,
	): Promise<MonjaMessage> {
		return parseMessage(
			await this.#request(
				nonemptyString(this.tokens.personas[persona], "participant token"),
				"POST",
				`/channels/${encodeURIComponent(channelId)}/messages`,
				{ content, parentMessageId: rootId, idempotencyKey },
			),
			`${persona} reply`,
		);
	}

	async getThread(rootId: string): Promise<MonjaThread> {
		const value = record(
			await this.#request(
				this.tokens.coordinator,
				"GET",
				`/messages/${encodeURIComponent(rootId)}/thread`,
			),
			"thread",
		);
		if (!Array.isArray(value["replies"])) {
			throw new Error("thread.replies must be an array");
		}
		return {
			root: parseMessage(value["root"], "thread.root"),
			replies: value["replies"].map((item, index) =>
				parseMessage(item, `thread.replies[${index}]`),
			),
		};
	}

	async linkTask(taskId: string, messageId: string): Promise<void> {
		await this.#request(
			this.tokens.coordinator,
			"POST",
			`/tasks/${encodeURIComponent(taskId)}/links`,
			{ messageId },
		);
	}

	async completeTask(taskId: string): Promise<void> {
		await this.#request(
			this.tokens.coordinator,
			"PATCH",
			`/tasks/${encodeURIComponent(taskId)}`,
			{ status: "done" },
		);
	}
}
