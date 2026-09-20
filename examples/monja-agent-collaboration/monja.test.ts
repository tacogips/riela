import { describe, expect, test } from "bun:test";
import { FakeMonjaServer } from "./fake-monja";
import { HttpMonjaGateway } from "./monja";

const coordinatorTokens = (token: string) => ({
	coordinator: token,
	personas: { architect: token, skeptic: token, integrator: token },
});

async function withServer(
	handler: (request: Request) => Response | Promise<Response>,
	operation: (baseUrl: string) => Promise<void>,
): Promise<void> {
	const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: handler });
	try {
		await operation(`http://127.0.0.1:${server.port}/api/v1`);
	} finally {
		server.stop(true);
	}
}

describe("HttpMonjaGateway", () => {
	test("resolves a task linked to a reply from its canonical thread", async () => {
		const root = {
			id: "root",
			channelId: "channel",
			authorId: "owner",
			parentMessageId: null,
			content: "root content",
		};
		const reply = {
			id: "linked-reply",
			channelId: "channel",
			authorId: "author",
			parentMessageId: root.id,
			content: "reply content",
		};
		const requests: string[] = [];
		await withServer(
			(request) => {
				const path = new URL(request.url).pathname;
				requests.push(path);
				if (path === "/api/v1/tasks/task")
					return Response.json({
						task: {
							id: "task",
							title: "Task",
							description: "",
							status: "open",
						},
						links: [{ message: reply }],
					});
				if (path === "/api/v1/messages/linked-reply/thread")
					return Response.json({
						root,
						replies: [{ ...reply, id: "other-reply" }, reply],
					});
				return new Response(null, { status: 404 });
			},
			async (baseUrl) => {
				const detail = await new HttpMonjaGateway(
					baseUrl,
					coordinatorTokens("test-token"),
				).getTask("task");
				expect(detail.linkedMessages).toEqual([reply]);
				expect(requests).toEqual([
					"/api/v1/tasks/task",
					"/api/v1/messages/linked-reply/thread",
				]);
			},
		);
	});
	test("exercises every successful API operation and canonical linked root", async () => {
		const server = new FakeMonjaServer();
		const tokens = {
			coordinator: server.credentials.coordinator,
			personas: {
				architect: server.credentials.architect,
				skeptic: server.credentials.skeptic,
				integrator: server.credentials.integrator,
			},
		};
		try {
			const gateway = new HttpMonjaGateway(`${server.apiUrl}/`, tokens);
			const authors = await gateway.getExpectedAuthors();
			expect(authors.personas["architect"]).toBe("fixture-architect-user");
			expect((await gateway.getTask(server.task.id)).linkedMessages).toEqual(
				[],
			);

			const root = await gateway.createRoot(
				server.channelId,
				"root content",
				"root-key",
			);
			await gateway.linkTask(server.task.id, root.id);
			const detail = await gateway.getTask(server.task.id);
			expect(detail.task).toEqual(server.task);
			expect(detail.linkedMessages).toEqual([root]);
			const reply = await gateway.postTurn(
				"architect",
				server.channelId,
				root.id,
				"reply content",
				"reply-key",
			);
			expect((await gateway.getThread(root.id)).replies).toEqual([reply]);
			await gateway.completeTask(server.task.id);
			expect(server.task.status).toBe("done");
		} finally {
			server.stop();
		}
	});

	test("rejects insecure remote HTTP and non-success responses", async () => {
		expect(
			() =>
				new HttpMonjaGateway(
					"http://example.invalid/api/v1",
					coordinatorTokens("test-token"),
				),
		).toThrow("HTTPS or loopback HTTP");
		await withServer(
			() => Response.json({ error: "denied" }, { status: 403 }),
			async (baseUrl) => {
				await expect(
					new HttpMonjaGateway(
						baseUrl,
						coordinatorTokens("test-token"),
					).getThread("root"),
				).rejects.toThrow("Monja GET /messages/root/thread failed (403)");
			},
		);
	});

	test("rejects malformed principals, messages, tasks, and threads", async () => {
		const cases: readonly {
			readonly body: unknown;
			readonly operation: (gateway: HttpMonjaGateway) => Promise<unknown>;
			readonly message: string;
		}[] = [
			{
				body: { user: {} },
				operation: (gateway) => gateway.getExpectedAuthors(),
				message: "authenticated principal.user.id must be a nonempty string",
			},
			{
				body: {
					id: "m",
					channelId: "c",
					authorId: "a",
					parentMessageId: 4,
					content: "x",
				},
				operation: (gateway) => gateway.createRoot("c", "x", "key"),
				message: "created root.parentMessageId must be a string or null",
			},
			{
				body: { task: { id: "t", title: "T", status: "unknown" }, links: [] },
				operation: (gateway) => gateway.getTask("t"),
				message: "task.status is invalid",
			},
			{
				body: { task: { id: "t", title: "T", status: "open" }, links: {} },
				operation: (gateway) => gateway.getTask("t"),
				message: "task detail.links must be an array",
			},
			{
				body: { root: {}, replies: {} },
				operation: (gateway) => gateway.getThread("root"),
				message: "thread.replies must be an array",
			},
		];
		for (const testCase of cases) {
			await withServer(
				() => Response.json(testCase.body),
				async (baseUrl) => {
					await expect(
						testCase.operation(
							new HttpMonjaGateway(baseUrl, coordinatorTokens("test-token")),
						),
					).rejects.toThrow(testCase.message);
				},
			);
		}
	});

	test("rejects linked-message absence and canonical disagreement", async () => {
		for (const mode of ["absent", "different"] as const) {
			await withServer(
				(request) => {
					const path = new URL(request.url).pathname;
					if (path.endsWith("/tasks/t")) {
						return Response.json({
							task: { id: "t", title: "T", status: "open" },
							links: [
								{
									message: {
										id: "linked",
										channelId: "channel",
										authorId: "author",
										parentMessageId: null,
										content: "visible",
									},
								},
							],
						});
					}
					return Response.json({
						root: {
							id: mode === "absent" ? "other" : "linked",
							channelId: "channel",
							authorId: "author",
							parentMessageId: null,
							content: mode === "different" ? "changed" : "visible",
						},
						replies: [],
					});
				},
				async (baseUrl) => {
					await expect(
						new HttpMonjaGateway(
							baseUrl,
							coordinatorTokens("test-token"),
						).getTask("t"),
					).rejects.toThrow(
						mode === "absent"
							? "is absent from its canonical thread"
							: "disagrees with its canonical thread",
					);
				},
			);
		}
	});

	test("accepts null links and a 204 link response", async () => {
		await withServer(
			(request) =>
				request.method === "POST"
					? new Response(null, { status: 204 })
					: Response.json({
							task: { id: "t", title: "T", description: 3, status: "open" },
							links: [{ message: null }],
						}),
			async (baseUrl) => {
				const gateway = new HttpMonjaGateway(
					baseUrl,
					coordinatorTokens("test-token"),
				);
				expect((await gateway.getTask("t")).task.description).toBe("");
				await gateway.linkTask("t", "root");
			},
		);
	});
});
