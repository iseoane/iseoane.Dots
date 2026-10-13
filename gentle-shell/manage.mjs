// gentle-shell: only allowlisted settings.json keys are user-owned. Extensions,
// npm, auth.json and models-store.json are tool state and never versioned.
import { lstat, mkdir, readFile, readdir, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoDir = dirname(fileURLToPath(import.meta.url));
const settingsKeys = ["theme", "tuiMode", "packages"];
const allowedFiles = new Set(["manage.mjs", "settings.json"]);

function parseArguments() {
  const [command, ...args] = process.argv.slice(2);
  const targetIndex = args.indexOf("--target");
  const target = targetIndex === -1 ? undefined : args[targetIndex + 1];
  if (!command || !["apply", "sync", "check"].includes(command)) {
    throw new Error("usage: node gentle-shell/manage.mjs <apply|sync|check> [--target <agent-dir>]");
  }
  if (targetIndex !== -1 && !target) throw new Error("--target requires a directory");
  return { command, targetDir: resolve(target ?? join(homedir(), ".gentle-shell", "agent")) };
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

const readJson = async (path) => JSON.parse(await readFile(path, "utf8"));

async function writeJson(path, value) {
  await mkdir(dirname(path), { recursive: true });
  const temporary = join(dirname(path), `.${basename(path)}.${process.pid}.tmp`);
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, path);
}

async function checkRepository() {
  for (const entry of await readdir(repoDir)) {
    if (!allowedFiles.has(entry)) throw new Error(`unmanaged gentle-shell file in repository: gentle-shell/${entry}`);
  }
  const settings = await readJson(join(repoDir, "settings.json"));
  for (const key of Object.keys(settings)) {
    if (!settingsKeys.includes(key)) throw new Error(`unmanaged gentle-shell setting in repository: ${key}`);
  }
  console.log("gentle-shell config: ok");
}

async function sync(targetDir) {
  const live = await readJson(join(targetDir, "settings.json"));
  const settings = Object.fromEntries(
    settingsKeys.filter((key) => Object.hasOwn(live, key)).map((key) => [key, live[key]]),
  );
  await writeJson(join(repoDir, "settings.json"), settings);
  await checkRepository();
  console.log(`gentle-shell config synced from ${targetDir}`);
}

async function apply(targetDir) {
  await checkRepository();
  const settingsPath = join(targetDir, "settings.json");
  const current = (await exists(settingsPath)) ? await readJson(settingsPath) : {};
  if (await exists(settingsPath)) {
    const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..+/, "").replace("T", "-");
    await writeJson(`${settingsPath}.bak-${stamp}`, current);
    console.log(`  backup -> ${settingsPath}.bak-${stamp}`);
  }
  await writeJson(settingsPath, { ...current, ...(await readJson(join(repoDir, "settings.json"))) });
  console.log(`gentle-shell config applied to ${targetDir}`);
}

const options = parseArguments();
if (options.command === "check") await checkRepository();
if (options.command === "sync") await sync(options.targetDir);
if (options.command === "apply") await apply(options.targetDir);
