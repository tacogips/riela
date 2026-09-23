export enum TaskStatus {
	Todo = "todo",
	Doing = "doing",
	Done = "done",
}
export enum RunStatus {
	Planned = "planned",
	Running = "running",
	Succeeded = "succeeded",
	Failed = "failed",
	Paused = "paused",
	Unknown = "unknown",
	CancelRequested = "cancel_requested",
}
export interface Task {
	id: string;
	projectId: string;
	title: string;
	description: string;
	status: TaskStatus;
}
export interface Project {
	projectId: string;
	channelId: string;
	directories: Record<string, string>;
	repositories: { directory: string; github: string }[];
	wrikeTasks: Record<string, string>;
	wrikeFolderId?: string;
}
export interface Plan {
	goal: string;
	steps: string[];
	scopes: string[];
	dependencies: string[];
	mergeKey: string;
	verification: string;
}
export interface Payload {
	workflow: Record<string, unknown>;
	nodePayloads: Record<string, Record<string, unknown>>;
}
export interface Run {
	key: string;
	task: Task;
	plan: Plan;
	payload: Payload;
	generation: number;
	status: RunStatus;
	sessionId: string | null;
	evidence: string;
	absorbed: string[];
	pendingMerge?: Task;
	checkpoints?: Checkpoint[];
	cancellationError?: string;
}
export interface Checkpoint {
	runKey: string;
	generation: number;
	sessionId: string | null;
	evidence: string;
	artifactReference: string;
	cancellationAcknowledged: boolean;
}
export interface Provider {
	tasks(): Promise<Task[]>;
	persist(run: Run): Promise<void>;
	status(taskId: string, status: TaskStatus): Promise<void>;
	notify(
		key: string,
		taskId: string,
		message: string,
		wrike: boolean,
	): Promise<void>;
}
export interface Executor {
	start(run: Run): Promise<void>;
	inspect(
		run: Run,
	): Promise<{ status: RunStatus; sessionId: string | null; evidence: string }>;
	pause(run: Run): Promise<boolean>;
}
export type Planner = (task: Task, previous: Run | null) => Promise<Plan>;
export function record(value: unknown): Record<string, unknown> {
	if (typeof value !== "object" || value === null || Array.isArray(value))
		throw new Error("Expected JSON object");
	return value as Record<string, unknown>;
}
export function string(value: unknown): string {
	if (typeof value !== "string") throw new Error("Expected string");
	return value;
}
export function strings(value: unknown): string[] {
	if (!Array.isArray(value)) throw new Error("Expected string array");
	return value.map(string);
}
export function parsePlan(value: unknown, scopes: string[]): Plan {
	const p = record(value);
	const plan = {
		goal: string(p["goal"]),
		steps: strings(p["steps"]),
		scopes: strings(p["scopes"]),
		dependencies: strings(p["dependencies"]),
		mergeKey: string(p["mergeKey"]),
		verification: string(p["verification"]),
	};
	if (
		!plan.goal ||
		!plan.steps.length ||
		!plan.scopes.length ||
		!plan.verification ||
		plan.scopes.some((s) => !scopes.includes(s))
	)
		throw new Error("Invalid planner contract or unknown write scope");
	return plan;
}
