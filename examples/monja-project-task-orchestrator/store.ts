import { Database } from "bun:sqlite";
import type { Run } from "./types";

/** Single-host durable scheduler state; SQLite transaction serializes acquisition. */
export class Store {
	readonly db: Database;
	constructor(path: string) {
		this.db = new Database(path, { create: true, strict: true });
		this.db.exec(
			"PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, body TEXT NOT NULL); CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY); CREATE TABLE IF NOT EXISTS outbox (id TEXT PRIMARY KEY, task TEXT NOT NULL, message TEXT NOT NULL, wrike INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS lease (id INTEGER PRIMARY KEY CHECK(id=1), pid INTEGER NOT NULL);",
		);
		this.db.exec(
			"CREATE TABLE IF NOT EXISTS mirrors (task TEXT PRIMARY KEY, id TEXT)",
		);
	}
	mirror(task: string): { id: string | null } | null {
		return this.db
			.query<{ id: string | null }, [string]>(
				"SELECT id FROM mirrors WHERE task=?",
			)
			.get(task);
	}
	saveMirror(task: string, id: string | null): void {
		this.db.query("INSERT OR REPLACE INTO mirrors VALUES (?, ?)").run(task, id);
	}
	acquire(): boolean {
		let acquired = false;
		this.db
			.transaction(() => {
				const owner = this.db
					.query<{ pid: number }, []>("SELECT pid FROM lease WHERE id=1")
					.get();
				if (owner) {
					try {
						process.kill(owner.pid, 0);
						return false;
					} catch (error) {
						if (
							!(
								error instanceof Error &&
								"code" in error &&
								error.code === "ESRCH"
							)
						)
							return false;
					}
				}
				this.db
					.query("INSERT OR REPLACE INTO lease VALUES (1, ?)")
					.run(process.pid);
				acquired = true;
				return true;
			})
			.immediate();
		return acquired;
	}
	release(): void {
		this.db.query("DELETE FROM lease WHERE id=1 AND pid=?").run(process.pid);
	}
	runs(): Run[] {
		// These records are generated and stored by this process, never accepted from HTTP.
		return this.db
			.query<{ body: string }, []>("SELECT body FROM runs ORDER BY id")
			.all()
			.map((row) => JSON.parse(row.body) as Run);
	}
	save(run: Run): void {
		this.db
			.query("INSERT OR REPLACE INTO runs VALUES (?, ?)")
			.run(run.task.id, JSON.stringify(run));
	}
	atomic(operation: () => void): void {
		this.db.transaction(operation)();
	}
	event(id: string, task: string): void {
		this.db.transaction(() => {
			const inserted = this.db
				.query("INSERT OR IGNORE INTO events VALUES (?)")
				.run(id);
			if (inserted.changes)
				this.enqueue(`receipt:${id}`, task, `Task received: ${task}`, false);
		})();
	}
	enqueue(id: string, task: string, message: string, wrike = true): void {
		this.db
			.query("INSERT OR IGNORE INTO outbox VALUES (?, ?, ?, ?)")
			.run(id, task, message, Number(wrike));
	}
	pending(): { id: string; task: string; message: string; wrike: number }[] {
		return this.db
			.query<{ id: string; task: string; message: string; wrike: number }, []>(
				"SELECT * FROM outbox ORDER BY rowid",
			)
			.all();
	}
	delivered(id: string): void {
		this.db.query("DELETE FROM outbox WHERE id=?").run(id);
	}
}
