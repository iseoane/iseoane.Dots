import assert from "node:assert/strict";
import { test } from "node:test";
import { collapseHome, expandHome, extractBlock, extractSettings, mergeSettings, replaceBlock } from "./manage.mjs";

const live = {
  model: "old",
  enabledPlugins: { a: true },
  hooks: {
    Stop: [
      { hooks: [{ type: "command", command: "/h/u/sync.sh push" }, { type: "command", command: "gentle-ai review stop-hook" }] },
    ],
    PreToolUse: [{ hooks: [{ type: "command", command: "gentle-ai sdd-preflight-hook" }] }],
  },
};

test("extractSettings drops gentle-ai hooks and unmanaged keys", () => {
  assert.deepEqual(extractSettings(live), {
    model: "old",
    hooks: { Stop: [{ hooks: [{ type: "command", command: "/h/u/sync.sh push" }] }] },
  });
});

test("mergeSettings keeps gentle-ai hooks and unmanaged keys", () => {
  const repo = { model: "new", hooks: { Stop: [{ hooks: [{ type: "command", command: "mine" }] }] } };
  const merged = mergeSettings(live, repo);
  assert.equal(merged.model, "new");
  assert.deepEqual(merged.enabledPlugins, { a: true });
  assert.deepEqual(merged.hooks.Stop.map((g) => g.hooks.map((h) => h.command)), [["mine"], ["gentle-ai review stop-hook"]]);
  assert.deepEqual(merged.hooks.PreToolUse, live.hooks.PreToolUse);
});

test("home paths round-trip", () => {
  const value = { c: "bash '/h/u/.claude/x.sh'" };
  assert.deepEqual(collapseHome(value, "/h/u"), { c: "bash '$HOME/.claude/x.sh'" });
  assert.deepEqual(expandHome(collapseHome(value, "/h/u"), "/h/u"), value);
});

test("user-rules block replace and insert", () => {
  const block = "<!-- dots:user-rules:start -->\nnew\n<!-- dots:user-rules:end -->\n";
  const text = "head\n<!-- dots:user-rules:start -->\nold\n<!-- dots:user-rules:end -->\ntail\n";
  assert.equal(replaceBlock(text, block), "head\n<!-- dots:user-rules:start -->\nnew\n<!-- dots:user-rules:end -->\ntail\n");
  assert.equal(extractBlock(replaceBlock("head\n", block)), block);
});
