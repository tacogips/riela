import { realpath } from "node:fs/promises";
import { relative, resolve, sep } from "node:path";
import { type Project, record, string } from "./types";

export async function loadProject(file: string, cwd: string): Promise<Project> {
	const outside = (path: string): boolean =>
		path === ".." || path.startsWith(`..${sep}`);
	const raw = record(await Bun.file(file).json());
	const directories: Record<string, string> = {};
	const roots: string[] = [];
	for (const [key, value] of Object.entries(record(raw["directories"]))) {
		const path = string(value);
		const full = await realpath(resolve(cwd, path));
		if (!key) throw new Error("Directory scope keys must be nonempty");
		if (
			roots.some(
				(root) =>
					!outside(relative(root, full)) || !outside(relative(full, root)),
			)
		)
			throw new Error(
				"Write scopes must not overlap; map a common parent as one scope",
			);
		roots.push(full);
		directories[key] = full;
	}
	if (!roots.length)
		throw new Error("At least one project directory is required");
	if (!Array.isArray(raw["repositories"]))
		throw new Error("repositories must be an array");
	const repositories = raw["repositories"].map((value) => {
		const r = record(value);
		const directory = string(r["directory"]);
		const github = string(r["github"]);
		if (
			!directories[directory] ||
			!/^https:\/\/github\.com\/[^/]+\/[^/]+$/.test(github)
		)
			throw new Error("Invalid repository mapping");
		return { directory, github };
	});
	const wrikeTasks: Record<string, string> = {};
	for (const [key, value] of Object.entries(record(raw["wrikeTasks"])))
		wrikeTasks[key] = string(value);
	return {
		projectId: string(raw["projectId"]),
		channelId: string(raw["channelId"]),
		directories,
		repositories,
		wrikeTasks,
		...(raw["wrikeFolderId"] === undefined
			? {}
			: { wrikeFolderId: string(raw["wrikeFolderId"]) }),
	};
}
