// Selective Claude Code config manager: only user-owned config is versioned.
// Tool-installed assets (gentle-ai agents/commands/skills/hooks, plugins) stay out.
import {
  chmod,
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

const claudeDir = dirname(fileURLToPath(import.meta.url));
export const settingsKeys = [
  "permissions",
  "model",
  "effortLevel",
  "language",
  "statusLine",
  "subagentStatusLine",
  "theme",
  "editorMode",
  "tui",
  "worktree",
  "advisorModel",
  "modelSettings",
  "autoMode",
  "askUserQuestionTimeout",
  "inputNeededNotifEnabled",
  "remoteControlAtStartup",
  "skipAutoPermissionPrompt",
  "skipDangerousModePermissionPrompt",
  "switchModelsOnFlag",
  "enableWorkflows",
  "workflowKeywordTriggerEnabled",
  "feedbackDrafts",
  "crossSessionInbound",
  "remote",
];
export const markerStart = "<!-- dots:user-rules:start -->";
export const markerEnd = "<!-- dots:user-rules:end -->";
const profiles = {
  gentle: {
    defaultTarget: join(homedir(), ".claude"),
    claudeMd: "block",
    scripts: ["statusline.sh", "subagent-statusline.sh", "hooks/herdr-agent-state.sh"],
    themes: [],
  },
  vanilla: {
    defaultTarget: join(homedir(), ".claude-vanilla"),
    claudeMd: "whole",
    scripts: [],
    themes: ["xeo-gta.json"],
  },
};
const forbiddenNames = new Set([
  "agents",
  "commands",
  "skills",
  "plugins",
  ".credentials.json",
  "projects",
  "sessions",
]);

function parseArguments() {
  const [command, ...args] = process.argv.slice(2);
  const valueOf = (flag) => {
    const index = args.indexOf(flag);
    if (index === -1) return undefined;
    if (!args[index + 1]) throw new Error(`${flag} requires a value`);
    return args[index + 1];
  };
  const profile = valueOf("--profile") ?? "gentle";
  if (!command || !["apply", "sync", "check"].includes(command) || !profiles[profile]) {
    throw new Error("usage: node claude/manage.mjs <apply|sync|check> [--profile gentle|vanilla] [--target <dir>]");
  }
  const target = valueOf("--target");
  return {
    command,
    profile,
    repoDir: join(claudeDir, profile),
    targetDir: resolve(target ?? profiles[profile].defaultTarget),
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

async function writeAtomic(path, content, mode = 0o600) {
  await mkdir(dirname(path), { recursive: true });
  const temporary = join(dirname(path), `.${basename(path)}.${process.pid}.tmp`);
  await writeFile(temporary, content, { mode });
  await rename(temporary, path);
}

const writeJson = (path, value) => writeAtomic(path, `${JSON.stringify(value, null, 2)}\n`);

function timestamp() {
  return new Date().toISOString().replace(/[-:]/g, "").replace(/\..+/, "").replace("T", "-");
}

async function backup(path, stamp) {
  if (!(await exists(path))) return;
  const destination = `${path}.bak-${stamp}`;
  await cp(path, destination, { recursive: true, errorOnExist: true });
  console.log(`  backup -> ${destination}`);
}

// Paths are stored as $HOME in the repo and expanded on apply, so the
// snapshot is portable across users/machines.
export function mapStrings(value, transform) {
  if (typeof value === "string") return transform(value);
  if (Array.isArray(value)) return value.map((item) => mapStrings(item, transform));
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, mapStrings(item, transform)]));
  }
  return value;
}
export const collapseHome = (value, home = homedir()) =>
  mapStrings(value, (text) => text.split(home + "/").join("$HOME/"));
export const expandHome = (value, home = homedir()) =>
  mapStrings(value, (text) => text.split("$HOME/").join(home + "/"));

const isGentleAiHook = (hook) => typeof hook?.command === "string" && /^gentle-ai(\s|$)/.test(hook.command.trim());

// Keep only hooks matching `keep`, dropping groups/events left empty.
export function filterHooks(hooks, keep) {
  const result = {};
  for (const [event, groups] of Object.entries(hooks ?? {})) {
    const kept = [];
    for (const group of groups ?? []) {
      const inner = (group.hooks ?? []).filter(keep);
      if (inner.length) kept.push({ ...group, hooks: inner });
    }
    if (kept.length) result[event] = kept;
  }
  return result;
}

export const userHooks = (hooks) => filterHooks(hooks, (hook) => !isGentleAiHook(hook));

// User hooks come from the repo; gentle-ai hooks are preserved from live.
export function mergeHooks(liveHooks, repoHooks) {
  const gentle = filterHooks(liveHooks, isGentleAiHook);
  const merged = {};
  for (const event of new Set([...Object.keys(repoHooks ?? {}), ...Object.keys(gentle)])) {
    merged[event] = [...(repoHooks?.[event] ?? []), ...(gentle[event] ?? [])];
  }
  return merged;
}

export function extractSettings(live) {
  const settings = Object.fromEntries(
    settingsKeys.filter((key) => Object.hasOwn(live, key)).map((key) => [key, live[key]]),
  );
  const hooks = userHooks(live.hooks);
  if (Object.keys(hooks).length) settings.hooks = hooks;
  return settings;
}

export function mergeSettings(live, repo) {
  const result = { ...live };
  for (const key of settingsKeys) {
    if (Object.hasOwn(repo, key)) result[key] = repo[key];
    else delete result[key];
  }
  const hooks = mergeHooks(live.hooks, repo.hooks);
  if (Object.keys(hooks).length) result.hooks = hooks;
  else delete result.hooks;
  return result;
}

export function extractBlock(text) {
  const start = text.indexOf(markerStart);
  const end = text.indexOf(markerEnd);
  if (start === -1 || end === -1 || end < start) return undefined;
  return text.slice(start, end + markerEnd.length) + "\n";
}

export function replaceBlock(text, block) {
  const start = text.indexOf(markerStart);
  const end = text.indexOf(markerEnd);
  const trimmed = block.replace(/\n+$/, "");
  if (start === -1 || end === -1 || end < start) {
    return `${text.replace(/\n*$/, "")}${text ? "\n\n" : ""}${trimmed}\n`;
  }
  return text.slice(0, start) + trimmed + text.slice(end + markerEnd.length);
}

function isOwnedStyle(text) {
  const frontmatter = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text)?.[1];
  if (!frontmatter) return false;
  const meta = /^meta:\s*\r?\n((?:[ \t]+.*\r?\n?)*)/m.exec(frontmatter)?.[1] ?? "";
  return /^[ \t]+owner:\s*["']?iseoane["']?\s*$/m.test(meta);
}

async function ownedStyles(directory) {
  if (!(await exists(directory))) return [];
  const names = [];
  for (const name of (await readdir(directory)).sort()) {
    if (name.endsWith(".md") && isOwnedStyle(await readFile(join(directory, name), "utf8"))) names.push(name);
  }
  return names;
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
      /(api.?key|access.?token|refresh.?token|secret|password|authorization|cookie)/i.test(key)
    ) {
      throw new Error(`literal credential-like value found at ${nextTrail.join(".")}`);
    }
    if (typeof item === "string" && /^https?:\/\/[^/\s:@]+:[^/\s@]+@/i.test(item)) {
      throw new Error(`URL credentials found at ${nextTrail.join(".")}`);
    }
    assertNoLiteralSecrets(item, nextTrail);
  }
}

async function checkRepository(profile, repoDir) {
  for (const directory of [claudeDir, repoDir]) {
    for (const entry of await readdir(directory)) {
      if (forbiddenNames.has(entry)) throw new Error(`forbidden Claude state in repository: ${join(directory, entry)}`);
    }
  }
  const settings = await readJson(join(repoDir, "settings.json"));
  assertNoLiteralSecrets(settings);
  for (const key of Object.keys(settings)) {
    if (key !== "hooks" && !settingsKeys.includes(key)) throw new Error(`unmanaged Claude setting in repository: ${key}`);
  }
  if (Object.keys(filterHooks(settings.hooks, isGentleAiHook)).length) {
    throw new Error("gentle-ai hooks must not be versioned");
  }
  const claudeMd = await readFile(join(repoDir, "CLAUDE.md"), "utf8");
  if (profiles[profile].claudeMd === "block" && extractBlock(claudeMd) !== claudeMd) {
    throw new Error("gentle CLAUDE.md must contain only the dots:user-rules block");
  }
  const styles = join(repoDir, "output-styles");
  if (await exists(styles)) {
    for (const name of await readdir(styles)) {
      if (!isOwnedStyle(await readFile(join(styles, name), "utf8"))) {
        throw new Error(`output style not owned by iseoane: ${name}`);
      }
    }
  }
  for (const script of profiles[profile].scripts) {
    if (!(await exists(join(repoDir, script)))) throw new Error(`missing Claude script: ${profile}/${script}`);
  }
  for (const theme of profiles[profile].themes) {
    await readJson(join(repoDir, "themes", theme));
  }
  console.log(`claude ${profile} config: ok`);
}

async function sync(profile, repoDir, targetDir) {
  const live = await readJson(join(targetDir, "settings.json"));
  await writeJson(join(repoDir, "settings.json"), collapseHome(extractSettings(live)));

  const liveMd = await readFile(join(targetDir, "CLAUDE.md"), "utf8");
  if (profiles[profile].claudeMd === "whole") {
    await writeAtomic(join(repoDir, "CLAUDE.md"), liveMd, 0o644);
  } else {
    const block = extractBlock(liveMd);
    if (!block) throw new Error(`no ${markerStart} block in ${join(targetDir, "CLAUDE.md")}`);
    await writeAtomic(join(repoDir, "CLAUDE.md"), block, 0o644);
  }

  const repoStyles = join(repoDir, "output-styles");
  await rm(repoStyles, { recursive: true, force: true });
  for (const name of await ownedStyles(join(targetDir, "output-styles"))) {
    await mkdir(repoStyles, { recursive: true });
    await cp(join(targetDir, "output-styles", name), join(repoStyles, name));
  }

  for (const script of profiles[profile].scripts) {
    const source = join(targetDir, script);
    if (!(await exists(source))) {
      console.log(`  skip: ${source} not found`);
      continue;
    }
    await mkdir(dirname(join(repoDir, script)), { recursive: true });
    await cp(source, join(repoDir, script), { force: true });
  }
  for (const theme of profiles[profile].themes) {
    const source = join(targetDir, "themes", theme);
    if (!(await exists(source))) {
      console.log(`  skip: ${source} not found`);
      continue;
    }
    await mkdir(join(repoDir, "themes"), { recursive: true });
    await cp(source, join(repoDir, "themes", theme), { force: true });
  }
  await checkRepository(profile, repoDir);
  console.log(`claude ${profile} config synced from ${targetDir}`);
}

async function apply(profile, repoDir, targetDir) {
  await checkRepository(profile, repoDir);
  const stamp = timestamp();
  await mkdir(targetDir, { recursive: true });

  const settingsPath = join(targetDir, "settings.json");
  const live = (await exists(settingsPath)) ? await readJson(settingsPath) : {};
  const repo = expandHome(await readJson(join(repoDir, "settings.json")));
  await backup(settingsPath, stamp);
  await writeJson(settingsPath, mergeSettings(live, repo));

  const mdPath = join(targetDir, "CLAUDE.md");
  const repoMd = await readFile(join(repoDir, "CLAUDE.md"), "utf8");
  await backup(mdPath, stamp);
  if (profiles[profile].claudeMd === "whole") {
    await writeAtomic(mdPath, repoMd, 0o644);
  } else {
    const liveMd = (await exists(mdPath)) ? await readFile(mdPath, "utf8") : "";
    await writeAtomic(mdPath, replaceBlock(liveMd, repoMd), 0o644);
  }

  const repoStyles = join(repoDir, "output-styles");
  if (await exists(repoStyles)) {
    for (const name of await readdir(repoStyles)) {
      const destination = join(targetDir, "output-styles", name);
      await backup(destination, stamp);
      await mkdir(dirname(destination), { recursive: true });
      await cp(join(repoStyles, name), destination, { force: true });
    }
  }

  for (const script of profiles[profile].scripts) {
    const destination = join(targetDir, script);
    await backup(destination, stamp);
    await mkdir(dirname(destination), { recursive: true });
    await cp(join(repoDir, script), destination, { force: true });
    await chmod(destination, 0o755);
  }
  for (const theme of profiles[profile].themes) {
    const destination = join(targetDir, "themes", theme);
    await backup(destination, stamp);
    await mkdir(dirname(destination), { recursive: true });
    await cp(join(repoDir, "themes", theme), destination, { force: true });
  }
  console.log(`claude ${profile} config applied to ${targetDir}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const options = parseArguments();
  if (options.command === "check") await checkRepository(options.profile, options.repoDir);
  if (options.command === "sync") await sync(options.profile, options.repoDir, options.targetDir);
  if (options.command === "apply") await apply(options.profile, options.repoDir, options.targetDir);
}
