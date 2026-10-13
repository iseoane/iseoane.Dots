import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const isWindows = process.platform === "win32";
const syncScript = join(homedir(), ".engram-sync", isWindows ? "sync.ps1" : "sync.sh");
const syncCommand = isWindows ? "pwsh.exe" : syncScript;
const execFileAsync = promisify(execFile);
// OpenCode V2 has no session.idle; a finished turn ends in one of these.
const V2_TURN_END = new Set([
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
]);

async function runSync(
  action: "pull" | "push",
  seconds: number,
  trigger: string,
  warn: (message: string) => Promise<unknown>,
) {
  try {
    await execFileAsync(syncCommand, syncArguments(action), {
      timeout: seconds * 1_000,
      windowsHide: true,
    });
  } catch (error) {
    const code = error && typeof error === "object" && "code" in error ? error.code : "unknown";
    await warn(`${action} desde ${trigger} terminó con código ${String(code)}`).catch(() => {});
  }
}

function syncArguments(action: "pull" | "push") {
  return isWindows
    ? ["-NoProfile", "-NonInteractive", "-File", syncScript, action]
    : [action];
}

// OpenCode V2 calls `setup(ctx)` and exposes events as an async stream.
type V2Context = {
  event: { subscribe: (input: { signal: AbortSignal }) => AsyncIterable<{ type: string }> };
};

async function setupEngramSyncV2(ctx: V2Context): Promise<() => Promise<void>> {
  const warn = async (message: string) => console.warn(`[engram-sync] ${message}`);
  const abort = new AbortController();
  // OpenCode no diferencia oficialmente startup de resume: el plugin se carga
  // al iniciar el proceso, así que éste es el equivalente más próximo.
  await runSync("pull", 120, "inicio del plugin", warn);
  void (async () => {
    // The stream ends when the server restarts; resubscribe until disposed.
    while (!abort.signal.aborted) {
      try {
        for await (const event of ctx.event.subscribe({ signal: abort.signal })) {
          // Equivalente aproximado al hook Stop de Claude Code.
          if (V2_TURN_END.has(event.type)) await runSync("push", 60, event.type, warn);
        }
      } catch {
        await new Promise((resolve) => setTimeout(resolve, 1_000));
      }
    }
  })();
  return async () => abort.abort();
}

export default { id: "engram-sync", setup: setupEngramSyncV2 };
