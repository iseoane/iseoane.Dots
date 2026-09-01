import type { Plugin } from "@opencode-ai/plugin";
import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const isWindows = process.platform === "win32";
const syncScript = join(homedir(), ".engram-sync", isWindows ? "sync.ps1" : "sync.sh");
const syncCommand = isWindows ? "pwsh.exe" : syncScript;
const execFileAsync = promisify(execFile);

function syncArguments(action: "pull" | "push") {
  return isWindows
    ? ["-NoProfile", "-NonInteractive", "-File", syncScript, action]
    : [action];
}

export const EngramSyncPlugin: Plugin = async ({ client }) => {
  const runSync = async (action: "pull" | "push", seconds: number, trigger: string) => {
    try {
      await execFileAsync(syncCommand, syncArguments(action), {
        timeout: seconds * 1_000,
        windowsHide: true,
      });
    } catch (error) {
      const code = error && typeof error === "object" && "code" in error ? error.code : "unknown";
      await client.app.log({
        body: {
          service: "engram-sync",
          level: "warn",
          message: `${action} desde ${trigger} terminó con código ${String(code)}`,
        },
      }).catch(() => {});
    }
  };

  // OpenCode no diferencia oficialmente startup de resume: el plugin se carga
  // al iniciar el proceso, así que éste es el equivalente más próximo.
  await runSync("pull", 120, "inicio del plugin");

  return {
    // Equivalente aproximado al hook Stop de Claude Code. Es síncrono: OpenCode
    // espera el push (máximo 60 s) antes de terminar el handler.
    event: async ({ event }) => {
      if (event.type === "session.idle") {
        await runSync("push", 60, "session.idle");
      }
    },
  };
};
