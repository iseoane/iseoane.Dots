import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
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
    pi.logger.error(`engram-sync ${action} terminó con código ${result.code}: ${result.stderr}`);
  }
}

export default function (pi: ExtensionAPI) {
  // Equivale a Claude Code SessionStart con matcher startup. OMP no expone
  // `reason` en session_start, así que el pull va sin condición.
  pi.on("session_start", async () => {
    await sync(pi, "pull", 120_000);
  });

  // Cubre el matcher resume: al reanudar o bifurcar, OMP sólo emite
  // session_switch. El pull es idempotente, así que repetirlo no molesta.
  pi.on("session_switch", async (event) => {
    if (event.reason === "resume" || event.reason === "fork") {
      await sync(pi, "pull", 120_000);
    }
  });

  // Equivale a Stop. OMP no tiene `agent_settled`: agent_end marca
  // willContinue cuando ya hay una continuación automática agendada, y en ese
  // caso todavía no es un settle visible para el usuario.
  pi.on("agent_end", async (event) => {
    if (event.willContinue) return;
    await sync(pi, "push", 60_000);
  });

  // Equivale a SessionEnd. El proceso queda separado para no bloquear el
  // cierre de OMP y se auto-limita a 120 segundos.
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
