import { spawnSync } from "node:child_process";
import {
  cp,
  lstat,
  mkdir,
  readFile,
  readdir,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoDir = dirname(fileURLToPath(import.meta.url));
const settingsKeys = [
  "theme",
  "hideThinkingBlock",
  "quietStartup",
  "steeringMode",
  "followUpMode",
  "collapseChangelog",
  "packages",
  "defaultProvider",
  "defaultModel",
];
const managedFiles = ["models.json", "mcp.json"];
const managedDirectories = ["extensions", "themes"];
const forbiddenNames = new Set([
  "auth.json",
  "mcp-cache.json",
  "models-store.json",
  "sessions",
  "pi-pretty",
  "node_modules",
  "calm",
]);

function parseArguments() {
  const [command, ...args] = process.argv.slice(2);
  const targetIndex = args.indexOf("--target");
  const target = targetIndex === -1 ? undefined : args[targetIndex + 1];
  if (!command || !["apply", "sync", "check"].includes(command)) {
    throw new Error("usage: node pi/manage.mjs <apply|sync|check> [--target <agent-dir>] [--skip-npm]");
  }
  if (targetIndex !== -1 && !target) throw new Error("--target requires a directory");
  return {
    command,
    skipNpm: args.includes("--skip-npm"),
    targetDir: resolve(target ?? process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent")),
  };
}

async function exists(path) {
  try {
    await lstat(path);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

async function readJson(path) {
  return JSON.parse(await readFile(path, "utf8"));
}

async function writeJson(path, value) {
  await mkdir(dirname(path), { recursive: true });
  const temporary = join(dirname(path), `.${basename(path)}.${process.pid}.tmp`);
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  try {
    await rename(temporary, path);
  } catch (error) {
    if (process.platform !== "win32" || !["EEXIST", "EPERM"].includes(error?.code)) throw error;
    await rm(path, { force: true });
    await rename(temporary, path);
  }
}

function timestamp() {
  return new Date().toISOString().replace(/[-:]/g, "").replace(/\..+/, "").replace("T", "-");
}

async function backup(path, stamp) {
  if (!(await exists(path))) return;
  const destination = `${path}.bak-${stamp}`;
  await cp(path, destination, { recursive: true, errorOnExist: true });
  console.log(`  backup -> ${destination}`);
}

async function assertNoSymlinks(path) {
  const info = await lstat(path);
  if (info.isSymbolicLink()) throw new Error(`refusing to copy symlink: ${path}`);
  if (!info.isDirectory()) return;
  for (const entry of await readdir(path)) await assertNoSymlinks(join(path, entry));
}

async function copyFile(source, destination) {
  await mkdir(dirname(destination), { recursive: true });
  await cp(source, destination, { force: true });
}

async function replaceDirectory(source, destination, stamp, withBackup) {
  await assertNoSymlinks(source);
  if (withBackup) await backup(destination, stamp);
  await rm(destination, { recursive: true, force: true });
  await mkdir(dirname(destination), { recursive: true });
  await cp(source, destination, { recursive: true });
}

function assertNoLiteralSecrets(value, trail = []) {
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertNoLiteralSecrets(item, [...trail, String(index)]));
    return;
  }
  if (!value || typeof value !== "object") return;
  for (const [key, item] of Object.entries(value)) {
    const nextTrail = [...trail, key];
    if (
      typeof item === "string" &&
      /(api.?key|access.?token|refresh.?token|secret|password|authorization|cookie)/i.test(key) &&
      !/\{(?:env|file):[^}]+\}/.test(item)
    ) {
      throw new Error(`literal credential-like value found at ${nextTrail.join(".")}`);
    }
    if (typeof item === "string" && /^https?:\/\/[^/\s:@]+:[^/\s@]+@/i.test(item)) {
      throw new Error(`URL credentials found at ${nextTrail.join(".")}`);
    }
    assertNoLiteralSecrets(item, nextTrail);
  }
}

function packageName(specifier) {
  const value = specifier.replace(/^npm:/, "");
  if (!value.startsWith("@")) return value.split("@")[0];
  const versionSeparator = value.indexOf("@", 1);
  return versionSeparator === -1 ? value : value.slice(0, versionSeparator);
}

async function checkRepository() {
  for (const entry of await readdir(repoDir)) {
    if (forbiddenNames.has(entry)) throw new Error(`forbidden Pi state in repository: pi/${entry}`);
  }

  const settings = await readJson(join(repoDir, "settings.json"));
  const models = await readJson(join(repoDir, "models.json"));
  const mcp = await readJson(join(repoDir, "mcp.json"));
  const packageJson = await readJson(join(repoDir, "npm", "package.json"));
  await readJson(join(repoDir, "npm", "package-lock.json"));
  await readJson(join(repoDir, "themes", "xeoTheme.json"));
  assertNoLiteralSecrets(settings);
  assertNoLiteralSecrets(models);
  assertNoLiteralSecrets(mcp);
  assertNoLiteralSecrets(packageJson);

  for (const key of Object.keys(settings)) {
    if (!settingsKeys.includes(key)) throw new Error(`unmanaged Pi setting in repository: ${key}`);
  }
  const dependencies = packageJson.dependencies ?? {};
  for (const specifier of settings.packages ?? []) {
    const name = packageName(specifier);
    if (!dependencies[name]) throw new Error(`Pi package missing from npm/package.json: ${name}`);
  }
  for (const required of ["@heyhuynhgiabuu/pi-pretty", "gentle-pi"]) {
    if (!dependencies[required]) throw new Error(`local extension dependency missing: ${required}`);
  }
  for (const file of ["pi-pretty.ts", "quiet-tools.ts", "codegraph-tools.ts", "terminal-status-title.js"]) {
    if (!(await exists(join(repoDir, "extensions", file)))) throw new Error(`missing Pi extension: ${file}`);
  }
  console.log("pi config: ok");
}

async function sync(targetDir) {
  const liveSettings = await readJson(join(targetDir, "settings.json"));
  const settings = Object.fromEntries(
    settingsKeys.filter((key) => Object.hasOwn(liveSettings, key)).map((key) => [key, liveSettings[key]]),
  );
  await writeJson(join(repoDir, "settings.json"), settings);

  for (const file of managedFiles) {
    const value = await readJson(join(targetDir, file));
    assertNoLiteralSecrets(value);
    await writeJson(join(repoDir, file), value);
  }
  for (const directory of managedDirectories) {
    await replaceDirectory(join(targetDir, directory), join(repoDir, directory), "", false);
  }
  await mkdir(join(repoDir, "npm"), { recursive: true });
  for (const file of ["package.json", "package-lock.json"]) {
    await copyFile(join(targetDir, "npm", file), join(repoDir, "npm", file));
  }
  await checkRepository();
  console.log(`pi config synced from ${targetDir}`);
}

async function apply(targetDir, skipNpm) {
  await checkRepository();
  const stamp = timestamp();
  await mkdir(targetDir, { recursive: true });

  const settingsPath = join(targetDir, "settings.json");
  const currentSettings = (await exists(settingsPath)) ? await readJson(settingsPath) : {};
  const managedSettings = await readJson(join(repoDir, "settings.json"));
  await backup(settingsPath, stamp);
  await writeJson(settingsPath, { ...currentSettings, ...managedSettings });

  for (const file of managedFiles) {
    const destination = join(targetDir, file);
    await backup(destination, stamp);
    await copyFile(join(repoDir, file), destination);
  }
  for (const directory of managedDirectories) {
    await replaceDirectory(join(repoDir, directory), join(targetDir, directory), stamp, true);
  }

  const npmDir = join(targetDir, "npm");
  await mkdir(npmDir, { recursive: true });
  for (const file of ["package.json", "package-lock.json"]) {
    const destination = join(npmDir, file);
    await backup(destination, stamp);
    await copyFile(join(repoDir, "npm", file), destination);
  }
  if (!skipNpm) {
    const npm = process.platform === "win32" ? "npm.cmd" : "npm";
    const result = spawnSync(npm, ["ci"], { cwd: npmDir, stdio: "inherit" });
    if (result.status !== 0) throw new Error(`npm ci failed with exit code ${result.status ?? "unknown"}`);
  }
  console.log(`pi config applied to ${targetDir}`);
}

const options = parseArguments();
if (options.command === "check") await checkRepository();
if (options.command === "sync") await sync(options.targetDir);
if (options.command === "apply") await apply(options.targetDir, options.skipNpm);
