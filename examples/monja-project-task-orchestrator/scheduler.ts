import type { Store } from "./store";
import {
	type Executor,
	type Planner,
	type Project,
	type Provider,
	type Run,
	RunStatus,
	TaskStatus,
} from "./types";
import { workflow } from "./workflow";

export class Scheduler {
	constructor(
		readonly project: Project,
		readonly store: Store,
		readonly provider: Provider,
		readonly executor: Executor,
		readonly planner: Planner,
	) {}
	async flush(): Promise<void> {
		for (const item of this.store.pending()) {
			await this.provider.notify(
				item.id,
				item.task,
				item.message,
				Boolean(item.wrike),
			);
			this.store.delivered(item.id);
		}
	}
	private async acknowledgePause(run: Run): Promise<void> {
		if (!(await this.executor.pause(run))) {
			const observed = await this.executor.inspect(run);
			if (observed.status === RunStatus.Succeeded) {
				// Completion won the race; ordinary completion handling below finalizes it.
				run.status = RunStatus.Running;
				delete run.pendingMerge;
				this.store.save(run);
			} else if (
				observed.status === RunStatus.Failed &&
				observed.evidence !== run.cancellationError
			) {
				run.cancellationError = observed.evidence;
				this.store.atomic(() => {
					this.store.save(run);
					this.store.enqueue(
						`${run.key}:merge-blocked`,
						run.task.id,
						`Merge blocked by terminal failure without cancellation acknowledgement. Incoming task ${run.pendingMerge?.id} remains reserved; inspect session ${observed.sessionId}: ${observed.evidence}`,
					);
				});
			}
			return;
		}
		const observed = await this.executor.inspect(run);
		run.status = RunStatus.Paused;
		run.sessionId = observed.sessionId ?? run.sessionId;
		const checkpoint = run.checkpoints?.find((c) => c.runKey === run.key);
		if (checkpoint) {
			checkpoint.sessionId = run.sessionId;
			checkpoint.evidence = `${checkpoint.evidence}\nCancellation acknowledgment: ${observed.evidence}`;
			checkpoint.cancellationAcknowledged = true;
		}
		this.store.atomic(() => {
			this.store.save(run);
			this.store.enqueue(
				`${run.key}:merge`,
				run.task.id,
				`Paused with cancellation acknowledgement; merging ${run.pendingMerge?.id} and replanning goal`,
			);
		});
	}
	async tick(): Promise<void> {
		if (!this.store.acquire()) return;
		try {
			// Deliver receipts before accepting work. Delivery failures remain durable.
			await this.flush();
			const tasks = await this.provider.tasks();
			for (const run of this.store
				.runs()
				.filter((r) => r.status === RunStatus.CancelRequested))
				await this.acknowledgePause(run);
			for (const run of this.store.runs()) {
				if (
					run.status !== RunStatus.Running &&
					run.status !== RunStatus.Unknown
				)
					continue;
				const observed = await this.executor.inspect(run);
				const changed = observed.evidence !== run.evidence;
				Object.assign(run, observed);
				this.store.atomic(() => {
					this.store.save(run);
					if (observed.status === RunStatus.Succeeded) {
						// Retry status updates on later ticks if the provider was unavailable.
						this.store.enqueue(
							`${run.key}:completed`,
							run.task.id,
							`Completed ${run.task.title}. Session ${run.sessionId}. ${run.evidence}`,
						);
						for (const id of run.absorbed)
							this.store.enqueue(
								`${run.key}:${id}:completed`,
								id,
								`Completed merged task ${id} in ${run.task.id}. Session ${run.sessionId}. ${run.evidence}`,
							);
					} else if (
						observed.status === RunStatus.Failed ||
						observed.status === RunStatus.Unknown
					) {
						this.store.enqueue(
							`${run.key}:failed`,
							run.task.id,
							`Execution ${run.status}: ${run.evidence}`,
						);
					} else if (changed)
						this.store.enqueue(
							`${run.key}:progress:${Bun.hash(run.evidence)}`,
							run.task.id,
							`Progress ${run.task.title}: ${run.evidence}`,
						);
				});
			}
			for (const run of this.store
				.runs()
				.filter((r) => r.status === RunStatus.Succeeded)) {
				for (const id of [run.task.id, ...run.absorbed]) {
					if (tasks.find((t) => t.id === id)?.status !== TaskStatus.Done)
						await this.provider.status(id, TaskStatus.Done);
				}
			}
			await this.flush();
			for (const paused of this.store
				.runs()
				.filter((r) => r.status === RunStatus.Paused && r.pendingMerge)) {
				const incoming = paused.pendingMerge;
				if (!incoming) continue;
				const combined = {
					...paused.task,
					description: `${paused.task.description}\n\nMerged task ${incoming.id}: ${incoming.title}\n${incoming.description}`,
				};
				const plan = await this.planner(combined, paused);
				const active = this.store
					.runs()
					.filter(
						(r) =>
							r.task.id !== paused.task.id &&
							[
								RunStatus.Running,
								RunStatus.Unknown,
								RunStatus.Planned,
								RunStatus.Paused,
								RunStatus.CancelRequested,
							].includes(r.status),
					);
				if (
					plan.dependencies.some(
						(id) =>
							id !== incoming.id &&
							tasks.find((t) => t.id === id)?.status !== TaskStatus.Done,
					) ||
					active.some((r) => r.plan.scopes.some((s) => plan.scopes.includes(s)))
				)
					continue;
				const generation = paused.generation + 1;
				const merged: Run = {
					...paused,
					task: combined,
					plan,
					generation,
					key: `${paused.task.id}:g${generation}`,
					payload: workflow(
						combined,
						plan,
						this.project,
						generation,
						paused.checkpoints,
					),
					absorbed: [...paused.absorbed, incoming.id],
					status: RunStatus.Planned,
					sessionId: null,
				};
				delete merged.pendingMerge;
				this.store.save(merged);
			}
			for (const task of tasks.filter((t) => t.status === TaskStatus.Todo)) {
				const existing = this.store.runs();
				if (
					existing.some(
						(r) =>
							r.task.id === task.id ||
							r.absorbed.includes(task.id) ||
							r.pendingMerge?.id === task.id,
					)
				)
					continue;
				this.store.event(`task:${task.id}`, task.id);
				await this.flush();
				const plan = await this.planner(task, null);
				if (
					plan.dependencies.some(
						(id) => tasks.find((t) => t.id === id)?.status !== TaskStatus.Done,
					)
				)
					continue;
				const active = existing.filter((r) =>
					[
						RunStatus.Running,
						RunStatus.Unknown,
						RunStatus.Planned,
						RunStatus.Paused,
						RunStatus.CancelRequested,
					].includes(r.status),
				);
				// Foreign doing work has no trustworthy write-scope/stop contract: wait.
				if (
					tasks.some(
						(t) =>
							t.status === TaskStatus.Doing &&
							!existing.some(
								(r) => r.task.id === t.id || r.absorbed.includes(t.id),
							),
					)
				)
					continue;
				const conflicts = active.filter((r) =>
					r.plan.scopes.some((s) => plan.scopes.includes(s)),
				);
				let run: Run;
				const merge = conflicts.length === 1 ? conflicts[0] : undefined;
				if (
					conflicts.length &&
					(!merge ||
						!plan.mergeKey ||
						merge.plan.mergeKey !== plan.mergeKey ||
						merge.status !== RunStatus.Running)
				)
					continue;
				if (merge) {
					merge.status = RunStatus.CancelRequested;
					merge.pendingMerge = task;
					merge.checkpoints = [
						...(merge.checkpoints ?? []),
						{
							runKey: merge.key,
							generation: merge.generation,
							sessionId: merge.sessionId,
							evidence: merge.evidence,
							artifactReference: `${merge.key}/artifacts`,
							cancellationAcknowledged: false,
						},
					];
					this.store.save(merge);
					await this.acknowledgePause(merge);
					continue;
				} else {
					run = {
						key: `${task.id}:g1`,
						task,
						plan,
						generation: 1,
						payload: workflow(task, plan, this.project, 1),
						status: RunStatus.Planned,
						sessionId: null,
						evidence: "",
						absorbed: [],
					};
				}
				this.store.save(run);
			}
			for (const run of this.store
				.runs()
				.filter((r) => r.status === RunStatus.Planned)) {
				await this.provider.persist(run);
				await this.provider.status(run.task.id, TaskStatus.Doing);
				this.store.enqueue(
					`${run.key}:started`,
					run.task.id,
					`Starting ${run.task.title}; goal: ${run.plan.goal}; generation ${run.generation}`,
				);
				await this.flush();
				// Reserve before launching. A crash in this window is ambiguous and never replays.
				run.status = RunStatus.Running;
				this.store.save(run);
				await this.executor.start(run);
			}
		} finally {
			this.store.release();
		}
	}
}
