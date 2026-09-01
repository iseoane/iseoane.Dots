import { realpathSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir, tmpdir } from "node:os";
import { parse, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
	mergeDisabledTools,
	PI_PRETTY_SUPPRESSED_TOOL_NAMES,
	quietToolsEnabled,
} from "../npm/node_modules/gentle-pi/lib/quiet-tools-config.ts";

// Upstream pi-pretty still reads HOME directly; native Windows may only set USERPROFILE.
process.env.HOME ??= homedir();

const packageJsonPath = realpathSync(
	fileURLToPath(new URL("../npm/package.json", import.meta.url)),
);
const requireFromPiPackages = createRequire(packageJsonPath);
const piPrettyModule = requireFromPiPackages("@heyhuynhgiabuu/pi-pretty");
const piPrettyExtension =
	typeof piPrettyModule === "function" ? piPrettyModule : piPrettyModule.default;

function isUnsafeFffRoot(cwd: string): boolean {
	const directory = resolve(cwd);
	return (
		directory === parse(directory).root ||
		directory === resolve(homedir()) ||
		directory === resolve(tmpdir())
	);
}

export default async function safePiPretty(pi: unknown, deps?: unknown): Promise<unknown> {
	if (isUnsafeFffRoot(process.cwd())) return;
	if (quietToolsEnabled()) {
		process.env.PRETTY_DISABLE_TOOLS = mergeDisabledTools(
			process.env.PRETTY_DISABLE_TOOLS,
			PI_PRETTY_SUPPRESSED_TOOL_NAMES,
		);
	}
	return piPrettyExtension(pi, deps);
}
