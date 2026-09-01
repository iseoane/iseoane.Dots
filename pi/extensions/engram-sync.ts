import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

const isWindows = process.platform === "win32";
const platformSyncScript = join(homedir(), ".engram-sync", isWindows ? "sync.ps1" : "sync.sh");

function syncCommand(action: "pull" | "push") {
  return isWindows
    ? { command: "pwsh.exe", args: ["-NoProfile", "-NonInteractive", "-File", platformSyncScript, action] }
    : { command: platformSyncScript, args: [action] };
}

async function sync(pi: ExtensionAPI, action: "pull" | "push", timeoutMs: number) {
  const { command, args } = syncCommand(action);
  const result = await pi.exec(command, args, { timeout: timeoutMs });

  if (result.code !== 0) {
    console.error(`engram-sync ${action} terminó con código ${result.code}: ${result.stderr}`);
  }
}

export default function (pi: ExtensionAPI) {
  // Equivale a Claude Code SessionStart con matcher startup|resume.
  pi.on("session_start", async (event) => {
    if (event.reason === "startup" || event.reason === "resume") {
      await sync(pi, "pull", 120_000);
    }
  });

  // Equivale a Stop: sólo ocurre cuando no quedan reintentos ni mensajes
  // pendientes. Es síncrono y espera como máximo 60 segundos.
  pi.on("agent_settled", async () => {
    await sync(pi, "push", 60_000);
  });

  // Equivale a SessionEnd. El proceso queda separado para no bloquear el
  // cierre de Pi y se auto-limita a 120 segundos.
  pi.on("session_shutdown", () => {
    const { command, args } = syncCommand("push");
    const runner = [
      "const { spawn } = require('node:child_process');",
      "const child = spawn(process.argv[1], JSON.parse(process.argv[2]), { stdio: 'ignore', windowsHide: true });",
      "const timer = setTimeout(() => child.kill(), 120000);",
      "child.on('exit', code => { clearTimeout(timer); process.exit(code ?? 1); });",
      "child.on('error', () => { clearTimeout(timer); process.exit(127); });",
    ].join(" ");
    const child = spawn(process.execPath, ["-e", runner, command, JSON.stringify(args)], {
      detached: true,
      stdio: "ignore",
      windowsHide: true,
    });
    child.unref();
  });
}
