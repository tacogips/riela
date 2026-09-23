export interface ParticipantConfig {
	readonly stepId: string;
	readonly displayName: string;
	readonly tokenEnv: string;
	readonly finalDecision: boolean;
}
export enum SessionStatus {
	Created = "created",
	Running = "running",
	Completed = "completed",
	Failed = "failed",
}
export enum LaunchKind {
	Initial = "initial",
	Recovery = "recovery",
}
export interface LaunchIntent {
	readonly id: string;
	readonly kind: LaunchKind;
	readonly sourceSessionId: string | null;
	readonly stepId: string | null;
	readonly sessionId: string | null;
}
export interface TurnRecord {
	readonly persona: string;
	readonly message: string;
	readonly details: Readonly<Record<string, unknown>>;
}
export interface PersonaOutput extends TurnRecord {
	readonly priorTurns: readonly TurnRecord[];
	readonly solved?: boolean;
	readonly unresolved?: readonly string[];
	readonly acceptanceCriteria?: readonly string[];
}
export interface MonjaTask {
	readonly id: string;
	readonly title: string;
	readonly description: string;
	readonly status: "open" | "in_progress" | "done";
}
export interface MonjaMessage {
	readonly id: string;
	readonly channelId: string;
	readonly authorId: string;
	readonly parentMessageId: string | null;
	readonly content: string;
}
export interface MonjaThread {
	readonly root: MonjaMessage;
	readonly replies: readonly MonjaMessage[];
}
export interface MonjaAuthorMap {
	readonly coordinator: string;
	readonly personas: Readonly<Record<string, string>>;
}
export interface RielaStepExecution {
	readonly stepId: string;
	readonly status: string;
	readonly acceptedPayload: unknown | null;
}
export interface RielaSessionView {
	readonly sessionId: string;
	readonly status: SessionStatus;
	readonly failureReason: string | null;
	readonly executions: readonly RielaStepExecution[];
}
export interface PublicationRequest {
	readonly content: string;
	readonly idempotencyKey: string;
	readonly messageId: string | null;
}
export interface CollaborationState {
	readonly version: 2;
	readonly taskId: string;
	readonly channelId: string;
	readonly participants: readonly ParticipantConfig[];
	readonly authors: MonjaAuthorMap;
	readonly task: MonjaTask;
	readonly root: PublicationRequest;
	readonly turns: Readonly<Record<string, PublicationRequest>>;
	readonly launches: readonly LaunchIntent[];
}
export interface CollaborationConfig {
	readonly taskId: string;
	readonly channelId: string;
	readonly participants: readonly ParticipantConfig[];
	readonly retryFailedStep: boolean;
	readonly completeTaskOnSuccess: boolean;
	readonly pollIntervalMs: number;
	readonly timeoutMs: number;
}
export interface CollaborationResult {
	readonly taskId: string;
	readonly rootMessageId: string;
	readonly sessionId: string;
	readonly published: Readonly<Record<string, string>>;
	readonly completedTask: boolean;
}
export interface MonjaGateway {
	getExpectedAuthors(): Promise<MonjaAuthorMap>;
	getTask(taskId: string): Promise<{
		readonly task: MonjaTask;
		readonly linkedMessages: readonly MonjaMessage[];
	}>;
	createRoot(
		channelId: string,
		content: string,
		idempotencyKey: string,
	): Promise<MonjaMessage>;
	postTurn(
		persona: string,
		channelId: string,
		rootId: string,
		content: string,
		idempotencyKey: string,
	): Promise<MonjaMessage>;
	getThread(rootId: string): Promise<MonjaThread>;
	linkTask(taskId: string, messageId: string): Promise<void>;
	completeTask(taskId: string): Promise<void>;
}
export interface RielaSessionRunner {
	preflight(participants: readonly ParticipantConfig[]): Promise<void>;
	launch(task: MonjaTask, intent: LaunchIntent): Promise<string>;
	reconcile(intent: LaunchIntent): Promise<string>;
	inspect(sessionId: string): Promise<RielaSessionView>;
}
export interface CollaborationStateStore {
	load(): Promise<CollaborationState | null>;
	save(state: CollaborationState): Promise<void>;
}
/** Narrow an external value to a JSON object. */
export function record(
	value: unknown,
	label = "value",
): Record<string, unknown> {
	if (typeof value !== "object" || value === null || Array.isArray(value))
		throw new Error(`${label} must be an object`);
	return value as Record<string, unknown>;
}
export function nonemptyString(value: unknown, label: string): string {
	if (typeof value !== "string" || value.trim().length === 0)
		throw new Error(`${label} must be a nonempty string`);
	return value;
}
export function stringArray(
	value: unknown,
	label: string,
	requireItem = false,
): readonly string[] {
	if (!Array.isArray(value)) throw new Error(`${label} must be an array`);
	const result = value.map((item, index) =>
		nonemptyString(item, `${label}[${index}]`),
	);
	if (requireItem && !result.length)
		throw new Error(`${label} must contain at least one item`);
	return result;
}
