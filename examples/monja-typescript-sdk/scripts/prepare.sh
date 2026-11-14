#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
riela_root=$(CDPATH='' cd -- "$script_dir/../../.." && pwd -P)
tmp_root="$riela_root/tmp"
monja_request=${MONJA_REPOSITORY_ROOT:-"$riela_root/../monja"}

if [ ! -d "$monja_request/packages/client-typescript" ]; then
  printf '%s\n' 'monja-prepare: Monja client package directory is missing' >&2
  exit 66
fi
monja_root=$(CDPATH='' cd -- "$monja_request" && pwd -P)
package_dir="$monja_root/packages/client-typescript"

mkdir -p "$tmp_root"
tmp_root=$(CDPATH='' cd -- "$tmp_root" && pwd -P)
runtime_request=${MONJA_EXAMPLE_RUNTIME_DIR:-"$tmp_root/monja-typescript-sdk/single-run"}

runtime_dir=$(node - "$tmp_root" "$runtime_request" <<'NODE'
import fs from "node:fs";
import path from "node:path";

const tmpRoot = fs.realpathSync(process.argv[2]);
const requested = path.resolve(process.argv[3]);
const relative = path.relative(tmpRoot, requested);
if (
  relative === "" ||
  path.isAbsolute(relative) ||
  relative === ".." ||
  relative.startsWith(`..${path.sep}`) ||
  !relative.startsWith(`monja-typescript-sdk${path.sep}`)
) {
  process.stderr.write("monja-prepare: runtime directory is outside the permitted Riela tmp tree\n");
  process.exit(65);
}

let current = tmpRoot;
for (const segment of relative.split(path.sep)) {
  current = path.join(current, segment);
  try {
    const metadata = fs.lstatSync(current);
    if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
      process.stderr.write("monja-prepare: runtime path contains a symlink or non-directory\n");
      process.exit(65);
    }
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    fs.mkdirSync(current, { mode: 0o700 });
  }
}

const canonical = fs.realpathSync(current);
const canonicalRelative = path.relative(tmpRoot, canonical);
if (
  path.isAbsolute(canonicalRelative) ||
  canonicalRelative === ".." ||
  canonicalRelative.startsWith(`..${path.sep}`)
) {
  process.stderr.write("monja-prepare: canonical runtime directory escaped Riela tmp\n");
  process.exit(65);
}
process.stdout.write(canonical);
NODE
)
export MONJA_EXAMPLE_RUNTIME_DIR="$runtime_dir"

consumer_dir="$runtime_dir/consumer"
evidence_dir="$runtime_dir/evidence"
pack_dir="$runtime_dir/package"
if [ -e "$consumer_dir" ] || [ -e "$pack_dir" ]; then
  printf '%s\n' 'monja-prepare: runtime already contains package-consumer state' >&2
  exit 65
fi
mkdir -p "$consumer_dir/src" "$evidence_dir" "$pack_dir"

npm --prefix "$package_dir" run build
npm --prefix "$package_dir" run typecheck
npm --prefix "$package_dir" test

npm pack "$package_dir" --json --pack-destination "$pack_dir" >"$evidence_dir/npm-pack.json"
tarball=$(node - "$evidence_dir/npm-pack.json" "$pack_dir" <<'NODE'
import fs from "node:fs";
import path from "node:path";

const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (!Array.isArray(report) || report.length !== 1) throw new Error("npm pack returned an unexpected report");
const entry = report[0];
if (entry?.name !== "@monja/client" || typeof entry.version !== "string" || typeof entry.filename !== "string") {
  throw new Error("npm pack reported the wrong package identity");
}
const packRoot = fs.realpathSync(process.argv[3]);
const candidate = path.resolve(packRoot, entry.filename);
const canonical = fs.realpathSync(candidate);
const relative = path.relative(packRoot, canonical);
if (relative === "" || path.isAbsolute(relative) || relative === ".." || relative.startsWith(`..${path.sep}`)) {
  throw new Error("reported npm tarball escaped its pack directory");
}
process.stdout.write(canonical);
NODE
)

tar -tzf "$tarball" >"$evidence_dir/package-files.txt"
node - "$evidence_dir/package-files.txt" <<'NODE'
import fs from "node:fs";

const members = fs.readFileSync(process.argv[2], "utf8").split(/\r?\n/u).filter(Boolean);
const required = new Set(["package/dist/index.js", "package/dist/index.d.ts", "package/package.json"]);
for (const member of members) {
  if (member.startsWith("/") || member.split("/").includes("..")) throw new Error("package archive contains an escaping member");
  if (member.startsWith("package/src/")) throw new Error("package archive contains workspace source");
  required.delete(member);
}
if (required.size !== 0) throw new Error(`package archive is missing required members: ${[...required].join(", ")}`);
NODE

tar -xOzf "$tarball" package/package.json >"$evidence_dir/packed-package.json"
packed_version=$(node - "$evidence_dir/packed-package.json" "$evidence_dir/npm-pack.json" <<'NODE'
import fs from "node:fs";

const manifest = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const report = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
if (manifest.name !== "@monja/client" || typeof manifest.version !== "string") {
  throw new Error("packed manifest has the wrong identity");
}
if (!Array.isArray(report) || report.length !== 1 || report[0]?.name !== manifest.name || report[0]?.version !== manifest.version) {
  throw new Error("npm pack report and packed manifest identities differ");
}
for (const section of ["dependencies", "optionalDependencies", "peerDependencies"]) {
  for (const value of Object.values(manifest[section] ?? {})) {
    if (
      typeof value === "string" &&
      (value.startsWith("workspace:") || value.startsWith("link:") || value.startsWith("file:"))
    ) {
      throw new Error("packed manifest contains a workspace-only dependency");
    }
  }
}
process.stdout.write(manifest.version);
NODE
)
shasum -a 256 "$tarball" >"$evidence_dir/package.sha256"

node - "$consumer_dir/package.json" "$tarball" <<'NODE'
import fs from "node:fs";

const manifest = {
  name: "riela-monja-typescript-sdk-consumer",
  private: true,
  type: "module",
  dependencies: { "@monja/client": `file:${process.argv[3]}` },
  devDependencies: { typescript: "5.7.2", "@types/node": "20.12.14" },
};
fs.writeFileSync(process.argv[2], `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
NODE

node - "$consumer_dir/tsconfig.json" <<'NODE'
import fs from "node:fs";

const config = {
  compilerOptions: {
    target: "ES2022",
    module: "NodeNext",
    moduleResolution: "NodeNext",
    lib: ["ES2022", "DOM", "DOM.Iterable"],
    types: ["node"],
    rootDir: "src",
    outDir: "dist",
    strict: true,
    exactOptionalPropertyTypes: true,
    noUncheckedIndexedAccess: true,
    useUnknownInCatchVariables: true,
    verbatimModuleSyntax: true,
    forceConsistentCasingInFileNames: true,
    noEmitOnError: true,
    skipLibCheck: false,
  },
  include: ["src/**/*.ts"],
};
fs.writeFileSync(process.argv[2], `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
NODE

cp "$script_dir/../nodes/monja-command.ts" "$consumer_dir/src/monja-command.ts"
cp "$script_dir/../nodes/monja-url-policy.ts" "$consumer_dir/src/monja-url-policy.ts"
cp "$consumer_dir/package.json" "$evidence_dir/consumer-package.json"
cp "$consumer_dir/tsconfig.json" "$evidence_dir/consumer-tsconfig.json"

(
  cd "$consumer_dir"
  npm install --ignore-scripts --no-audit --no-fund --package-lock=true
)

node - "$consumer_dir" "$tarball" "$packed_version" "$evidence_dir/installed-top-level.json" <<'NODE'
import fs from "node:fs";
import path from "node:path";

const consumer = fs.realpathSync(process.argv[2]);
const tarball = fs.realpathSync(process.argv[3]);
const expectedVersion = process.argv[4];
const manifest = JSON.parse(fs.readFileSync(path.join(consumer, "package.json"), "utf8"));
const lock = JSON.parse(fs.readFileSync(path.join(consumer, "package-lock.json"), "utf8"));
const installed = {
  monja: JSON.parse(fs.readFileSync(path.join(consumer, "node_modules/@monja/client/package.json"), "utf8")).version,
  typescript: JSON.parse(fs.readFileSync(path.join(consumer, "node_modules/typescript/package.json"), "utf8")).version,
  nodeTypes: JSON.parse(fs.readFileSync(path.join(consumer, "node_modules/@types/node/package.json"), "utf8")).version,
};
function resolvesToTarball(reference) {
  if (typeof reference !== "string" || !reference.startsWith("file:")) return false;
  const referencedPath = reference.slice("file:".length);
  return fs.realpathSync(path.resolve(consumer, referencedPath)) === tarball;
}
if (manifest.dependencies?.["@monja/client"] !== `file:${tarball}`) throw new Error("consumer dependency does not name the reported canonical tarball");
if (
  JSON.stringify(Object.keys(manifest.dependencies ?? {}).sort()) !== JSON.stringify(["@monja/client"]) ||
  JSON.stringify(Object.keys(manifest.devDependencies ?? {}).sort()) !== JSON.stringify(["@types/node", "typescript"])
) {
  throw new Error("consumer manifest contains unexpected top-level dependencies");
}
if (installed.monja !== expectedVersion || installed.typescript !== "5.7.2" || installed.nodeTypes !== "20.12.14") {
  throw new Error("installed top-level dependency versions do not match the accepted pins");
}
const lockedRoot = lock.packages?.[""];
const lockedMonja = lock.packages?.["node_modules/@monja/client"];
if (
  lockedRoot?.dependencies?.["@monja/client"] !== `file:${tarball}` ||
  lockedRoot?.devDependencies?.typescript !== "5.7.2" ||
  lockedRoot?.devDependencies?.["@types/node"] !== "20.12.14" ||
  lockedMonja?.version !== expectedVersion ||
  !resolvesToTarball(lockedMonja?.resolved)
) {
  throw new Error("lockfile does not record the exact tarball and tool versions");
}
for (const relativePath of ["node_modules/.bin/tsc", "node_modules/@types/node/package.json"]) {
  const resolved = fs.realpathSync(path.join(consumer, relativePath));
  const containment = path.relative(path.join(consumer, "node_modules"), resolved);
  if (path.isAbsolute(containment) || containment === ".." || containment.startsWith(`..${path.sep}`)) {
    throw new Error("consumer tooling resolved outside its own node_modules");
  }
}
fs.writeFileSync(process.argv[5], `${JSON.stringify(installed, null, 2)}\n`, { mode: 0o600 });
NODE

(
  cd "$consumer_dir"
  ./node_modules/.bin/tsc --noEmit
  ./node_modules/.bin/tsc
)

grep -q 'from "@monja/client"' "$consumer_dir/dist/monja-command.js"
if grep -Eq 'require\(|module\.exports' "$consumer_dir/dist/monja-command.js" "$consumer_dir/dist/monja-url-policy.js"; then
  printf '%s\n' 'monja-prepare: CommonJS syntax found in NodeNext output' >&2
  exit 1
fi

(
  cd "$consumer_dir"
  node --input-type=module - "$evidence_dir/esm-resolution.json" <<'NODE'
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

if (typeof globalThis.fetch !== "function" || typeof import.meta.resolve !== "function") {
  throw new Error("Node runtime lacks required fetch or ESM resolution capabilities");
}
const resolved = fs.realpathSync(fileURLToPath(import.meta.resolve("@monja/client")));
const expected = fs.realpathSync(path.join(process.cwd(), "node_modules/@monja/client/dist/index.js"));
if (resolved !== expected) throw new Error("@monja/client resolved outside the isolated consumer");
await import("@monja/client");
fs.writeFileSync(process.argv[2], `${JSON.stringify({ nodeVersion: process.version, resolvedPackageEntry: resolved }, null, 2)}\n`, { mode: 0o600 });
NODE
)

printf '%s\n' 'monja-prepare: isolated consumer prepared successfully'
