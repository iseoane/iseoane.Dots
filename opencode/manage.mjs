import { cp, lstat, mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoDir = dirname(fileURLToPath(import.meta.url));
const managedFiles = ["opencode.json", "opencode.jsonc", "tui.json"];
const managedDirectories = [
  "themes",
  "agent",
  "agents",
  "command",
  "commands",
  "skill",
  "skills",
  "plugin",
  "plugins",
  "tool",
  "tools",
];
const forbiddenNames = new Set([
  "auth.json",
  "node_modules",
  "opencode.db",
  "opencode.db-shm",
  "opencode.db-wal",
  "log",
  "tool-output",
  "prompt-history.jsonl",
  "model.json",
]);

function parseArguments() {
  const [command, ...args] = process.argv.slice(2);
  const targetIndex = args.indexOf("--target");
  const target = targetIndex === -1 ? undefined : args[targetIndex + 1];
  if (!command || !["apply", "sync", "check"].includes(command)) {
    throw new Error("usage: node opencode/manage.mjs <apply|sync|check> [--target <config-dir>]");
  }
  if (targetIndex !== -1 && !target) throw new Error("--target requires a directory");
  const configHome = process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config");
  return { command, targetDir: resolve(target ?? join(configHome, "opencode")) };
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

function stripJsonComments(input) {
  let output = "";
  let inString = false;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;
  for (let index = 0; index < input.length; index += 1) {
    const char = input[index];
    const next = input[index + 1];
    if (lineComment) {
      if (char === "\n") {
        lineComment = false;
        output += char;
      }
      continue;
    }
    if (blockComment) {
      if (char === "*" && next === "/") {
        blockComment = false;
        index += 1;
      } else if (char === "\n") {
        output += char;
      }
      continue;
    }
    if (!inString && char === "/" && next === "/") {
      lineComment = true;
      index += 1;
      continue;
    }
    if (!inString && char === "/" && next === "*") {
      blockComment = true;
      index += 1;
      continue;
    }
    output += char;
    if (inString) {
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === '"') inString = false;
    } else if (char === '"') {
      inString = true;
    }
  }
  return output;
}

async function readConfig(path) {
  const contents = await readFile(path, "utf8");
  return JSON.parse(path.endsWith(".jsonc") ? stripJsonComments(contents) : contents);
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

async function copyFileAtomic(source, destination) {
  await mkdir(dirname(destination), { recursive: true });
  const temporary = join(dirname(destination), `.${basename(destination)}.${process.pid}.tmp`);
  await cp(source, temporary, { force: true });
  try {
    await rename(temporary, destination);
  } catch (error) {
    if (process.platform !== "win32" || !["EEXIST", "EPERM"].includes(error?.code)) throw error;
    await rm(destination, { force: true });
    await rename(temporary, destination);
  }
}

async function replaceDirectory(source, destination, stamp, withBackup) {
  await assertNoSymlinks(source);
  if (withBackup) await backup(destination, stamp);
  await rm(destination, { recursive: true, force: true });
  await mkdir(dirname(destination), { recursive: true });
  await cp(source, destination, { recursive: true });
}

async function checkRepository() {
  for (const entry of await readdir(repoDir)) {
    if (forbiddenNames.has(entry)) throw new Error(`forbidden OpenCode state in repository: opencode/${entry}`);
  }
  let configFound = false;
  for (const file of managedFiles) {
    const path = join(repoDir, file);
    if (!(await exists(path))) continue;
    const config = await readConfig(path);
    assertNoLiteralSecrets(config);
    if (file.startsWith("opencode.")) configFound = true;
  }
  if (!configFound) throw new Error("missing opencode.json or opencode.jsonc");

  const themes = join(repoDir, "themes");
  if (await exists(themes)) {
    for (const file of await readdir(themes)) {
      if (file.endsWith(".json")) assertNoLiteralSecrets(await readConfig(join(themes, file)));
    }
  }
  console.log("opencode config: ok");
}

async function sync(targetDir) {
  for (const file of managedFiles) {
    const source = join(targetDir, file);
    if (!(await exists(source))) continue;
    const config = await readConfig(source);
    assertNoLiteralSecrets(config);
    await copyFileAtomic(source, join(repoDir, file));
  }
  for (const directory of managedDirectories) {
    const source = join(targetDir, directory);
    if (await exists(source)) await replaceDirectory(source, join(repoDir, directory), "", false);
  }
  await checkRepository();
  console.log(`opencode config synced from ${targetDir}`);
}

async function apply(targetDir) {
  await checkRepository();
  const stamp = timestamp();
  await mkdir(targetDir, { recursive: true });
  for (const file of managedFiles) {
    const source = join(repoDir, file);
    if (!(await exists(source))) continue;
    const destination = join(targetDir, file);
    await backup(destination, stamp);
    await copyFileAtomic(source, destination);
  }
  for (const directory of managedDirectories) {
    const source = join(repoDir, directory);
    if (!(await exists(source))) continue;
    await replaceDirectory(source, join(targetDir, directory), stamp, true);
  }
  console.log(`opencode config applied to ${targetDir}`);
}

const options = parseArguments();
if (options.command === "check") await checkRepository();
if (options.command === "sync") await sync(options.targetDir);
if (options.command === "apply") await apply(options.targetDir);
