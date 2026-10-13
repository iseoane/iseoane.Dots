import { cp, lstat, mkdir, readFile, readdir, rename, rm } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoDir = dirname(fileURLToPath(import.meta.url));
// Only user-owned files are versioned. Everything else in ~/.config/opencode is
// installed by its tool and must never be stored here or overwritten by apply:
// gentle-ai (`gentle-ai sync`): opencode.json, agents/, commands/, skills/,
//   package.json and its plugins; engram (`engram setup opencode`):
//   plugins/engram.ts; herdr (`herdr integration install opencode`): herdr
//   plugins and tui entries.
const managedFiles = ["opencode.jsonc", "plugins/engram-sync.ts"];
const managedDirectories = ["themes"];
const allowedTopLevel = new Set(["manage.mjs", "opencode.jsonc", "plugins", "themes"]);
const toolOwnedNames = new Set([
  "opencode.json",
  "package.json",
  "package-lock.json",
  "tui.json",
  "tui.jsonc",
  "agent",
  "agents",
  "command",
  "commands",
  "skill",
  "skills",
  "tool",
  "tools",
  "auth.json",
  "node_modules",
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
      !/\{(?:env|file):[^}]+\}/.test(item) &&
      !["allow", "ask", "deny"].includes(item)
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

async function listFiles(path, prefix = "") {
  if (!(await exists(path))) return [];
  const files = [];
  for (const entry of await readdir(path)) {
    const full = join(path, entry);
    const info = await lstat(full);
    if (info.isSymbolicLink()) throw new Error(`refusing to copy symlink: ${full}`);
    if (info.isDirectory()) files.push(...(await listFiles(full, join(prefix, entry))));
    else files.push(join(prefix, entry));
  }
  return files;
}

function assertNoLegacyMcp(config) {
  const mcp = config?.mcp;
  if (!mcp || typeof mcp !== "object") return;
  const legacy = Object.keys(mcp).filter((key) => key !== "servers");
  if (legacy.length > 0) {
    throw new Error(`legacy OpenCode 1.x mcp entries in opencode.jsonc (use mcp.servers): ${legacy.join(", ")}`);
  }
}

async function checkRepository() {
  for (const entry of await readdir(repoDir)) {
    if (toolOwnedNames.has(entry) || !allowedTopLevel.has(entry)) {
      throw new Error(`tool-owned or unexpected file in repository: opencode/${entry}`);
    }
  }
  for (const file of await listFiles(join(repoDir, "plugins"))) {
    if (file !== "engram-sync.ts") throw new Error(`tool-owned plugin in repository: opencode/plugins/${file}`);
  }
  const configPath = join(repoDir, "opencode.jsonc");
  if (!(await exists(configPath))) throw new Error("missing opencode.jsonc");
  const config = await readConfig(configPath);
  assertNoLiteralSecrets(config);
  assertNoLegacyMcp(config);
  for (const file of await listFiles(join(repoDir, "themes"))) {
    if (file.endsWith(".json")) assertNoLiteralSecrets(await readConfig(join(repoDir, "themes", file)));
  }
  console.log("opencode config: ok");
}

async function sync(targetDir) {
  for (const file of managedFiles) {
    const source = join(targetDir, file);
    const destination = join(repoDir, file);
    if (!(await exists(source))) {
      await rm(destination, { force: true });
      continue;
    }
    if (file.endsWith(".jsonc")) assertNoLiteralSecrets(await readConfig(source));
    await copyFileAtomic(source, destination);
  }
  for (const directory of managedDirectories) {
    const destination = join(repoDir, directory);
    await rm(destination, { recursive: true, force: true });
    for (const file of await listFiles(join(targetDir, directory))) {
      await copyFileAtomic(join(targetDir, directory, file), join(destination, file));
    }
  }
  await checkRepository();
  console.log(`opencode config synced from ${targetDir}`);
}

// Apply merges: it only writes the versioned user files (with backups) and
// never deletes or touches files installed by gentle-ai, engram or herdr.
async function apply(targetDir) {
  await checkRepository();
  const stamp = timestamp();
  const files = [...managedFiles];
  for (const directory of managedDirectories) {
    for (const file of await listFiles(join(repoDir, directory))) files.push(join(directory, file));
  }
  for (const file of files) {
    const source = join(repoDir, file);
    if (!(await exists(source))) continue;
    const destination = join(targetDir, file);
    const unchanged =
      (await exists(destination)) &&
      (await readFile(source, "utf8")) === (await readFile(destination, "utf8"));
    if (unchanged) continue;
    await backup(destination, stamp);
    await copyFileAtomic(source, destination);
  }
  console.log(`opencode config applied to ${targetDir}`);
}

const options = parseArguments();
if (options.command === "check") await checkRepository();
if (options.command === "sync") await sync(options.targetDir);
if (options.command === "apply") await apply(options.targetDir);
