import { test } from "bun:test";
import { verifyWorkflow } from "./verify-workflow";

test("the real Riela CLI validates, inspects, and runs the fixture", async () => {
	await verifyWorkflow();
}, 30_000);
