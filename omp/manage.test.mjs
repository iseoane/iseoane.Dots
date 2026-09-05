import assert from "node:assert/strict";
import { cp, mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const sourceDir = dirname(fileURLToPath(import.meta.url));
const sandbox = await mkdtemp(join(tmpdir(), "omp-manager-test-"));
const ompDir = join(sandbox, "omp");
const agent = join(sandbox, "agent");
const plugins = join(sandbox, "plugins");

function run(command, expectedStatus = 0) {
  const result = spawnSync(process.execPath, [join(ompDir, "manage.mjs"), ...command], { encoding: "utf8" });
  assert.equal(result.status, expectedStatus, `${result.stdout}\n${result.stderr}`);
  return result;
}

try {
  await cp(sourceDir, ompDir, { recursive: true });
  await mkdir(join(agent, "extensions"), { recursive: true });
  await mkdir(plugins, { recursive: true });
  await writeFile(join(agent, "config.yml"), "extendedContext: true\n");
  await writeFile(join(agent, "models.yml"), "providers: {}\n");
  await writeFile(join(agent, "PERSONALITY.md"), "old\n");
  await writeFile(join(agent, "extensions", "old.ts"), "export {};\n");
  await writeFile(join(plugins, "package.json"), '{"name":"old"}\n');

  run(["apply", "--target", agent, "--plugins-target", plugins, "--skip-install"]);
  assert.match(await readFile(join(agent, "config.yml"), "utf8"), /^extendedContext: false$/m);
  assert.equal(JSON.parse(await readFile(join(plugins, "package.json"), "utf8")).name, "omp-plugins");
  const backupResult = spawnSync("bash", ["-lc", `compgen -G '${agent}/config.yml.bak-*'`], { encoding: "utf8" });
  assert.equal(backupResult.status, 0, "apply did not create a config backup");

  await writeFile(join(agent, "config.yml"), "theme:\n  dark: titanium\nextendedContext: false\n");
  await writeFile(join(agent, "extensions", "custom.ts"), "export default {};\n");
  await writeFile(join(agent, "extensions", "herdr-omp-agent-state.ts"), "machine-managed\n");
  run(["sync", "--target", agent, "--plugins-target", plugins]);
  assert.equal(await readFile(join(ompDir, "extensions", "custom.ts"), "utf8"), "export default {};\n");
  await assert.rejects(readFile(join(ompDir, "extensions", "herdr-omp-agent-state.ts")));
  run(["apply", "--target", agent, "--plugins-target", plugins, "--skip-install"]);
  assert.equal(await readFile(join(agent, "extensions", "herdr-omp-agent-state.ts"), "utf8"), "machine-managed\n");

  await writeFile(join(agent, "config.yml"), "apiKey: literal-secret\nextendedContext: false\n");
  const rejected = run(["sync", "--target", agent, "--plugins-target", plugins], 1);
  assert.match(rejected.stderr, /literal credential-like value/);
  console.log("omp manager tests: ok");
} finally {
  await rm(sandbox, { recursive: true, force: true });
}
