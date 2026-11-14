import { createHash } from "node:crypto";
import { isDeepStrictEqual } from "node:util";
import { parseParticipants } from "./participants";
import { parsePersonaOutput, turnRecord } from "./persona-output";
import {
	type CollaborationConfig,
	type CollaborationResult,
	type CollaborationState,
	type CollaborationStateStore,
	type LaunchIntent,
	LaunchKind,
	type MonjaAuthorMap,
	type MonjaGateway,
	type MonjaMessage,
	nonemptyString,
	type ParticipantConfig,
	type PersonaOutput,
	type PublicationRequest,
	type RielaSessionRunner,
	type RielaSessionView,
	SessionStatus,
	type TurnRecord,
} from "./types";

export const marker = (taskId: string, part: string): string =>
	`[riela-collaboration:${taskId}:${part}]`;
const key = (taskId: string, channelId: string, part: string): string =>
	"collaboration-" +
	createHash("sha256")
		.update(JSON.stringify([taskId, channelId, part]))
		.digest("hex");
export function turnContent(
	taskId: string,
	output: PersonaOutput,
	participant: ParticipantConfig,
): string {
	return (
		`${marker(taskId, participant.stepId)}\n${participant.displayName} (${participant.stepId})\n\n${output.message}\n\n${JSON.stringify(output.details, null, 2)}` +
		(participant.finalDecision
			? `\n\nSolved: ${output.solved}\nUnresolved: ${JSON.stringify(output.unresolved)}\nAcceptance criteria: ${JSON.stringify(output.acceptanceCriteria)}`
			: "")
	);
}
function verify(
	message: MonjaMessage,
	state: CollaborationState,
	request: PublicationRequest,
	parent: string | null,
	author: string,
): void {
	if (
		(request.messageId !== null && message.id !== request.messageId) ||
		message.channelId !== state.channelId ||
		message.parentMessageId !== parent ||
		message.authorId !== author ||
		message.content !== request.content
	) {
		throw new Error(
			"Canonical message has invalid id, channel, parent, author, or content",
		);
	}
}
function acceptedOutputs(
	session: RielaSessionView,
	participants: readonly ParticipantConfig[],
): readonly PersonaOutput[] {
	const outputs: PersonaOutput[] = [];
	const transcript: TurnRecord[] = [];
	for (const p of participants) {
		const accepted = session.executions.filter(
			(e) =>
				e.stepId === p.stepId &&
				e.status === "completed" &&
				e.acceptedPayload !== null,
		);
		if (accepted.length > 1)
			throw new Error(`Riela has ambiguous completed ${p.stepId} output`);
		const execution = accepted[0];
		if (!execution) break;
		const output = parsePersonaOutput(p, execution.acceptedPayload, transcript);
		outputs.push(output);
		transcript.push(turnRecord(output));
	}
	return outputs;
}

/** One durable task discussion. Call under the state store's exclusive writer lock. */
export class CollaborationRunner {
	constructor(
		readonly monja: MonjaGateway,
		readonly riela: RielaSessionRunner,
		readonly store: CollaborationStateStore,
	) {}
	async #root(state: CollaborationState): Promise<CollaborationState> {
		const request = state.root;
		const root = request.messageId
			? (await this.monja.getThread(request.messageId)).root
			: await this.monja.createRoot(
					state.channelId,
					request.content,
					request.idempotencyKey,
				);
		verify(root, state, request, null, state.authors.coordinator);
		const updated = { ...state, root: { ...request, messageId: root.id } };
		await this.store.save(updated);
		await this.monja.linkTask(state.taskId, root.id);
		const links = (await this.monja.getTask(state.taskId)).linkedMessages;
		const linked = links.find((m) => m.id === root.id);
		if (!linked)
			throw new Error("Collaboration root failed task-link postcondition");
		verify(linked, updated, updated.root, null, state.authors.coordinator);
		return updated;
	}
	async #turn(
		state: CollaborationState,
		participant: ParticipantConfig,
		output: PersonaOutput,
	): Promise<CollaborationState> {
		const rootId = nonemptyString(state.root.messageId, "root identity");
		const content = turnContent(state.taskId, output, participant);
		let request = Object.hasOwn(state.turns, participant.stepId)
			? state.turns[participant.stepId]
			: undefined;
		if (request && request.content !== content)
			throw new Error(
				"Accepted output changed an immutable publication request",
			);
		if (!request) {
			request = {
				content,
				idempotencyKey: key(state.taskId, state.channelId, participant.stepId),
				messageId: null,
			};
			state = {
				...state,
				turns: { ...state.turns, [participant.stepId]: request },
			};
			await this.store.save(state);
		}
		const author = nonemptyString(
			state.authors.personas[participant.stepId],
			"participant author",
		);
		const thread = await this.monja.getThread(rootId);
		const marked = thread.replies.filter((m) =>
			m.content.includes(marker(state.taskId, participant.stepId)),
		);
		if (marked.length > 1)
			throw new Error("Duplicate participant replies require reconciliation");
		let reply = request.messageId
			? thread.replies.find((m) => m.id === request.messageId)
			: marked[0];
		if (request.messageId && !reply)
			throw new Error("Persisted reply is no longer observable");
		if (!reply)
			reply = await this.monja.postTurn(
				participant.stepId,
				state.channelId,
				rootId,
				request.content,
				request.idempotencyKey,
			);
		verify(reply, state, request, rootId, author);
		const updated = {
			...state,
			turns: {
				...state.turns,
				[participant.stepId]: { ...request, messageId: reply.id },
			},
		};
		await this.store.save(updated);
		return updated;
	}
	async #launch(
		state: CollaborationState,
		source: string | null,
		step: string | null,
	): Promise<CollaborationState> {
		const intent: LaunchIntent = {
			id: crypto.randomUUID(),
			kind: source ? LaunchKind.Recovery : LaunchKind.Initial,
			sourceSessionId: source,
			stepId: step,
			sessionId: null,
		};
		state = { ...state, launches: [...state.launches, intent] };
		await this.store.save(state); // Intent and log identity exist BEFORE any child can run.
		const sessionId = await this.riela.launch(state.task, intent);
		return this.#saveSession(state, sessionId);
	}
	async #saveSession(
		state: CollaborationState,
		sessionId: string,
	): Promise<CollaborationState> {
		const last = state.launches.at(-1);
		if (!last) throw new Error("Missing durable launch intent");
		const updated = {
			...state,
			launches: [...state.launches.slice(0, -1), { ...last, sessionId }],
		};
		await this.store.save(updated);
		return updated;
	}
	async run(config: CollaborationConfig): Promise<CollaborationResult> {
		const participants = parseParticipants(config.participants);
		nonemptyString(config.taskId, "taskId");
		nonemptyString(config.channelId, "channelId");
		if (
			![config.pollIntervalMs, config.timeoutMs].every(
				(n) => Number.isSafeInteger(n) && n > 0,
			)
		)
			throw new Error("Polling and timeout must be positive integers");
		const persisted = await this.store.load();
		if (
			persisted &&
			(persisted.taskId !== config.taskId ||
				persisted.channelId !== config.channelId ||
				!isDeepStrictEqual(persisted.participants, participants))
		)
			throw new Error(
				"State belongs to a different task, channel, or participant configuration",
			);
		await this.riela.preflight(participants);
		const [authors, detail] = await Promise.all([
			this.monja.getExpectedAuthors(),
			this.monja.getTask(config.taskId),
		]);
		this.#validateAuthors(authors, participants);
		if (detail.task.id !== config.taskId)
			throw new Error("Monja returned different task identity");
		if (persisted && !isDeepStrictEqual(persisted.authors, authors))
			throw new Error(
				"Authenticated authors differ from durable discussion identity",
			);
		let state: CollaborationState = persisted ?? {
			version: 2,
			taskId: config.taskId,
			channelId: config.channelId,
			participants,
			authors,
			task: detail.task,
			root: {
				content: `${marker(config.taskId, "root")}\nRiela agent collaboration for task: ${detail.task.title}`,
				idempotencyKey: key(config.taskId, config.channelId, "root"),
				messageId: null,
			},
			turns: {},
			launches: [],
		};
		if (!persisted) await this.store.save(state); // Freeze original request before publication.
		state = await this.#root(state);
		const pending = state.launches.at(-1);
		let recoveryAttempted =
			pending?.kind === LaunchKind.Recovery && pending.sessionId === null;
		if (!pending) state = await this.#launch(state, null, null);
		else if (!pending.sessionId)
			state = await this.#saveSession(
				state,
				await this.riela.reconcile(pending),
			);
		const deadline = Date.now() + config.timeoutMs;
		while (Date.now() < deadline) {
			const sessionId = nonemptyString(
				state.launches.at(-1)?.sessionId,
				"session identity",
			);
			const session = await this.riela.inspect(sessionId);
			if (session.sessionId !== sessionId)
				throw new Error("Riela returned a different session identity");
			const outputs = acceptedOutputs(session, participants);
			for (const [i, output] of outputs.entries()) {
				const participant = participants[i];
				if (participant) state = await this.#turn(state, participant, output);
			}
			if (session.status === SessionStatus.Failed) {
				const target = participants[outputs.length];
				if (!config.retryFailedStep || recoveryAttempted || !target)
					throw new Error(
						`Riela collaboration failed: ${session.failureReason ?? "unknown failure"}; use explicit retry after repairing the failed step`,
					);
				recoveryAttempted = true;
				state = await this.#launch(state, sessionId, target.stepId);
				continue;
			}
			if (session.status === SessionStatus.Completed) {
				if (outputs.length !== participants.length)
					throw new Error("Not all configured turns have completed outputs");
				const final = outputs.at(-1);
				if (
					!final?.solved ||
					final.unresolved?.length !== 0 ||
					!final.acceptanceCriteria?.length
				)
					throw new Error(
						"Final decision is not solved with acceptance evidence; task remains open",
					);
				const rootId = nonemptyString(state.root.messageId, "root identity");
				const canonical = await this.monja.getThread(rootId);
				verify(canonical.root, state, state.root, null, authors.coordinator);
				const published: Record<string, string> = {};
				for (const p of participants) {
					const request = state.turns[p.stepId];
					const reply = canonical.replies.find(
						(m) => m.id === request?.messageId,
					);
					if (!request || !reply)
						throw new Error("Published reply is no longer observable");
					verify(
						reply,
						state,
						request,
						rootId,
						nonemptyString(authors.personas[p.stepId], "author"),
					);
					if (
						canonical.replies.filter((m) =>
							m.content.includes(marker(state.taskId, p.stepId)),
						).length !== 1
					)
						throw new Error(
							"Duplicate participant replies require reconciliation",
						);
					published[p.stepId] = reply.id;
				}
				if (
					config.completeTaskOnSuccess &&
					(await this.monja.getTask(config.taskId)).task.status !== "done"
				)
					await this.monja.completeTask(config.taskId);
				return {
					taskId: config.taskId,
					rootMessageId: rootId,
					sessionId,
					published,
					completedTask: config.completeTaskOnSuccess,
				};
			}
			await Bun.sleep(config.pollIntervalMs);
		}
		throw new Error("Riela collaboration did not complete before the deadline");
	}
	#validateAuthors(
		authors: MonjaAuthorMap,
		participants: readonly ParticipantConfig[],
	): void {
		nonemptyString(authors.coordinator, "coordinator author");
		const identities = participants.map((p) =>
			nonemptyString(authors.personas[p.stepId], "participant author"),
		);
		if (new Set(identities).size !== participants.length)
			throw new Error("Participants must authenticate as distinct bot authors");
	}
}
