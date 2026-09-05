import { spawnSync } from "node:child_process";
import { cp, lstat, mkdir, readFile, readdir, rename, rm } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoDir = dirname(fileURLToPath(import.meta.url));
const managedFiles = ["config.yml", "models.yml", "PERSONALITY.md"];
const managedDirectories = ["agents", "commands", "extensions", "skills", "themes"];
const pluginFiles = ["package.json", "bun.lock", "bun.lockb"];
const ignoredExtensionNames = new Set(["herdr-omp-agent-state.ts"]);
const forbiddenNames = new Set([
  ".env", "agent.db", "agent.db-shm", "agent.db-wal", "auth.json", "blobs", "cache",
  "history.db", "history.db-shm", "history.db-wal", "last-changelog-version", "logs",
  "models.db", "models.db-shm", "models.db-wal", "sessions", "terminal-sessions",
]);

function parseArguments() {
  const [command, ...args] = process.argv.slice(2);
  const targetIndex = args.indexOf("--target");
  const pluginsIndex = args.indexOf("--plugins-target");
  const target = targetIndex === -1 ? undefined : args[targetIndex + 1];
  const pluginsTarget = pluginsIndex === -1 ? undefined : args[pluginsIndex + 1];
  if (!command || !["apply", "sync", "check"].includes(command)) {
    throw new Error("usage: node omp/manage.mjs <apply|sync|check> [--target <agent-dir>] [--plugins-target <plugins-dir>] [--skip-install]");
  }
  if (targetIndex !== -1 && !target) throw new Error("--target requires a directory");
  if (pluginsIndex !== -1 && !pluginsTarget) throw new Error("--plugins-target requires a directory");
  return {
    command,
    skipInstall: args.includes("--skip-install"),
    targetDir: resolve(target ?? process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".omp", "agent")),
    pluginsDir: resolve(pluginsTarget ?? join(homedir(), ".omp", "plugins")),
  };
}

async function exists(path) {
  try { await lstat(path); return true; }
  catch (error) { if (error?.code === "ENOENT") return false; throw error; }
}

function timestamp() {
  return new Date().toISOString().replace(/[-:]/g, "").replace(/\..+/, "").replace("T", "-");
}

async function backup(path, stamp) {
  if (!(await exists(path))) return;
  let destination = `${path}.bak-${stamp}`;
  let counter = 1;
  while (await exists(destination)) destination = `${path}.bak-${stamp}-${counter++}`;
  await cp(path, destination, { recursive: true, errorOnExist: true });
  console.log(`  backup -> ${destination}`);
}

async function assertNoSymlinks(path) {
  const info = await lstat(path);
  if (info.isSymbolicLink()) throw new Error(`refusing to copy symlink: ${path}`);
  if (!info.isDirectory()) return;
  for (const entry of await readdir(path)) await assertNoSymlinks(join(path, entry));
}

function assertNoLiteralSecrets(contents, path) {
  const credentialAssignment = /^\s*(?:api[-_]?key|access[-_]?token|refresh[-_]?token|secret|password|authorization|cookie)\s*:\s*(?!\$\{|\{(?:env|file):)[^#\s].*$/im;
  if (credentialAssignment.test(contents) || /https?:\/\/[^/\s:@]+:[^/\s@]+@/i.test(contents) || /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/.test(contents)) {
    throw new Error(`literal credential-like value found in ${path}`);
  }
}

async function checkTextFile(path) {
  assertNoLiteralSecrets(await readFile(path, "utf8"), path);
}

async function checkTree(path) {
  await assertNoSymlinks(path);
  for (const entry of await readdir(path, { withFileTypes: true })) {
    const child = join(path, entry.name);
    if (entry.isDirectory()) await checkTree(child);
    else if (entry.isFile()) await checkTextFile(child);
  }
}

async function copyFileAtomic(source, destination) {
  await mkdir(dirname(destination), { recursive: true });
  const temporary = join(dirname(destination), `.${basename(destination)}.${process.pid}.tmp`);
  await cp(source, temporary, { force: true });
  await rename(temporary, destination);
}

async function replaceDirectory(source, destination, stamp, withBackup, ignored = new Set()) {
  await assertNoSymlinks(source);
  if (withBackup) await backup(destination, stamp);
  const preserved = `${destination}.preserved-${process.pid}`;
  await rm(preserved, { recursive: true, force: true });
  if (await exists(destination)) {
    for (const entry of ignored) {
      const current = join(destination, entry);
      if (await exists(current)) {
        await mkdir(preserved, { recursive: true });
        await cp(current, join(preserved, entry), { recursive: true });
      }
    }
  }
  await rm(destination, { recursive: true, force: true });
  await mkdir(destination, { recursive: true });
  for (const entry of await readdir(source)) {
    if (!ignored.has(entry)) await cp(join(source, entry), join(destination, entry), { recursive: true });
  }
  if (await exists(preserved)) {
    for (const entry of await readdir(preserved)) {
      await cp(join(preserved, entry), join(destination, entry), { recursive: true });
    }
    await rm(preserved, { recursive: true, force: true });
  }
}

async function checkRepository() {
  for (const entry of await readdir(repoDir)) {
    if (forbiddenNames.has(entry)) throw new Error(`forbidden OMP state in repository: omp/${entry}`);
  }
  for (const file of managedFiles) {
    const path = join(repoDir, file);
    if (!(await exists(path))) throw new Error(`missing OMP config: omp/${file}`);
    await checkTextFile(path);
  }
  const config = await readFile(join(repoDir, "config.yml"), "utf8");
  if (!/^extendedContext:\s*false\s*$/m.test(config)) throw new Error("OMP config must preserve extendedContext: false");
  for (const directory of managedDirectories) {
    const path = join(repoDir, directory);
    if (await exists(path)) await checkTree(path);
  }
  const packagePath = join(repoDir, "plugins", "package.json");
  await checkTextFile(packagePath);
  JSON.parse(await readFile(packagePath, "utf8"));
  console.log("omp config: ok");
}

async function sync(targetDir, pluginsDir) {
  for (const file of managedFiles) {
    const source = join(targetDir, file);
    if (!(await exists(source))) continue;
    await checkTextFile(source);
    await copyFileAtomic(source, join(repoDir, file));
  }
  for (const directory of managedDirectories) {
    const source = join(targetDir, directory);
    if (!(await exists(source))) continue;
    const ignored = directory === "extensions" ? ignoredExtensionNames : new Set();
    await checkTree(source);
    await replaceDirectory(source, join(repoDir, directory), "", false, ignored);
  }
  await mkdir(join(repoDir, "plugins"), { recursive: true });
  for (const file of pluginFiles) {
    const source = join(pluginsDir, file);
    if (await exists(source)) {
      await checkTextFile(source);
      await copyFileAtomic(source, join(repoDir, "plugins", file));
    }
    else await rm(join(repoDir, "plugins", file), { force: true });
  }
  await checkRepository();
  console.log(`omp config synced from ${targetDir}`);
}

async function apply(targetDir, pluginsDir, skipInstall) {
  await checkRepository();
  const stamp = timestamp();
  await mkdir(targetDir, { recursive: true });
  for (const file of managedFiles) {
    const destination = join(targetDir, file);
    await backup(destination, stamp);
    await copyFileAtomic(join(repoDir, file), destination);
  }
  for (const directory of managedDirectories) {
    const source = join(repoDir, directory);
    if (!(await exists(source))) continue;
    const ignored = directory === "extensions" ? ignoredExtensionNames : new Set();
    await replaceDirectory(source, join(targetDir, directory), stamp, true, ignored);
  }
  await mkdir(pluginsDir, { recursive: true });
  for (const file of pluginFiles) {
    const source = join(repoDir, "plugins", file);
    if (!(await exists(source))) continue;
    const destination = join(pluginsDir, file);
    await backup(destination, stamp);
    await copyFileAtomic(source, destination);
  }
  const manifest = JSON.parse(await readFile(join(repoDir, "plugins", "package.json"), "utf8"));
  const hasDependencies = Object.keys(manifest.dependencies ?? {}).length > 0;
  if (!skipInstall && hasDependencies) {
    const hasTextLock = await exists(join(repoDir, "plugins", "bun.lock"));
    const hasBinaryLock = await exists(join(repoDir, "plugins", "bun.lockb"));
    if (!hasTextLock && !hasBinaryLock) {
      throw new Error("OMP plugin dependencies require a versioned bun.lock or bun.lockb");
    }
    const result = spawnSync("bun", ["install", "--frozen-lockfile"], { cwd: pluginsDir, stdio: "inherit" });
    if (result.status !== 0) throw new Error(`bun install failed with exit code ${result.status ?? "unknown"}`);
  }
  console.log(`omp config applied to ${targetDir}`);
}

const options = parseArguments();
if (options.command === "check") await checkRepository();
if (options.command === "sync") await sync(options.targetDir, options.pluginsDir);
if (options.command === "apply") await apply(options.targetDir, options.pluginsDir, options.skipInstall);
