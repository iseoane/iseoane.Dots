#!/usr/bin/env python3
"""Merge codex/hooks.json's hook entries into a live ~/.codex-style hooks.json
without disturbing entries already there (e.g. Orca's per-event
`codex-hook.sh` dispatcher, injected directly into $CODEX_HOME/hooks.json on
machines where Codex CLI is Orca-wrapped). A hook entry is skipped if a group
with the same command already exists on that event; this makes re-running
apply-to-system.sh idempotent.

Usage: merge-hooks.py <desired-hooks.json> <target-hooks.json>
"""
import json
import sys


def main() -> None:
    desired_path, target_path = sys.argv[1], sys.argv[2]

    with open(desired_path, encoding="utf-8") as f:
        desired = json.load(f)

    try:
        with open(target_path, encoding="utf-8") as f:
            live = json.load(f)
    except FileNotFoundError:
        live = {"hooks": {}}

    for event, groups in desired["hooks"].items():
        live_groups = live["hooks"].setdefault(event, [])
        live_commands = {
            h.get("command") for g in live_groups for h in g.get("hooks", [])
        }
        for group in groups:
            commands = [h.get("command") for h in group.get("hooks", [])]
            if any(c in live_commands for c in commands):
                continue
            live_groups.append(group)

    with open(target_path, "w", encoding="utf-8") as f:
        json.dump(live, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
