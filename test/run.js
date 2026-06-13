#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const root = path.resolve(__dirname, "..");
const cli = path.join(root, "bin", "sidekick");
const tempHome = fs.mkdtempSync(path.join(os.tmpdir(), "sidekick-test-"));

function run(args, fixture) {
  const input = fixture ? fs.readFileSync(path.join(root, "fixtures", fixture), "utf8") : "";
  const result = spawnSync(cli, args, {
    input,
    encoding: "utf8",
    env: { ...process.env, SIDEKICK_HOME: tempHome, TMUX: "", TMUX_PANE: "" }
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
}

run(["hook", "codex"], "session-start.json");
run(["hook", "codex"], "prompt-submit.json");
run(["hook", "codex"], "stop.json");
run(["hook", "codex"], "stop.json");

const eventsFile = path.join(tempHome, "state", "events.jsonl");
const events = fs
  .readFileSync(eventsFile, "utf8")
  .trim()
  .split("\n")
  .map(JSON.parse);

assert.deepEqual(
  events.map((event) => event.eventType),
  ["session.started", "turn.started", "turn.completed"]
);
assert.equal(events[1].promptPreview.includes("secret-value"), false);
assert.equal(events[1].promptPreview.includes("[REDACTED]"), true);
assert.equal(events[2].turnId, events[1].turnId);
assert.equal(events[2].summaryPreview, "Sidekick MVP 구현과 검증을 완료했습니다.");

let tasks = JSON.parse(run(["list"]));
assert.equal(tasks.length, 1);
assert.equal(tasks[0].unread, true);

run(["read", tasks[0].eventId]);
tasks = JSON.parse(run(["list"]));
assert.equal(tasks[0].unread, false);

run(["hook", "codex"], "prompt-submit.json");
run(["hook", "codex"], "stop.json");
tasks = JSON.parse(run(["list"]));
assert.equal(tasks.length, 1);
assert.equal(tasks[0].turnNumber, 2);
assert.equal(tasks[0].unread, true);

const invalidFocus = spawnSync(cli, ["focus", "bad-pane"], {
  encoding: "utf8",
  env: { ...process.env, SIDEKICK_HOME: tempHome }
});
assert.equal(invalidFocus.status, 1);
assert.match(invalidFocus.stderr, /invalid tmux pane ID/);

const configHome = fs.mkdtempSync(path.join(os.tmpdir(), "sidekick-config-"));
fs.mkdirSync(path.join(configHome, ".codex"), { recursive: true });
fs.mkdirSync(path.join(configHome, ".codex-per"), { recursive: true });
fs.mkdirSync(path.join(configHome, ".claude"), { recursive: true });
fs.mkdirSync(path.join(configHome, ".claude-personal"), { recursive: true });
fs.writeFileSync(
  path.join(configHome, ".codex", "hooks.json"),
  JSON.stringify({ hooks: { Stop: [{ hooks: [{ type: "command", command: "existing-hook" }] }] } })
);
fs.writeFileSync(path.join(configHome, ".claude", "settings.json"), JSON.stringify({ hooks: {} }));
fs.writeFileSync(
  path.join(configHome, ".claude-personal", "settings.json"),
  JSON.stringify({ hooks: {} })
);
fs.writeFileSync(path.join(configHome, ".codex-per", "config.toml"), 'model = "test"\n');

for (let index = 0; index < 2; index += 1) {
  const configured = spawnSync("node", [path.join(root, "scripts", "configure.js"), "--apply"], {
    encoding: "utf8",
    env: {
      ...process.env,
      HOME: configHome,
      CODEX_HOME: path.join(configHome, ".codex"),
      SIDEKICK_HOME: path.join(configHome, ".sidekick")
    }
  });
  assert.equal(configured.status, 0, configured.stderr);
}

const codexHooks = JSON.parse(
  fs.readFileSync(path.join(configHome, ".codex", "hooks.json"), "utf8")
).hooks;
assert.equal(codexHooks.Stop[0].hooks[0].command, "existing-hook");
for (const eventName of ["SessionStart", "UserPromptSubmit", "Stop"]) {
  const sidekickHooks = codexHooks[eventName].flatMap((group) => group.hooks).filter((hook) =>
    hook.command.includes("/bin/sidekick hook codex")
  );
  assert.equal(sidekickHooks.length, 1);
}
const perHooks = JSON.parse(
  fs.readFileSync(path.join(configHome, ".codex-per", "hooks.json"), "utf8")
).hooks;
for (const eventName of ["SessionStart", "UserPromptSubmit", "Stop"]) {
  assert.equal(
    perHooks[eventName].flatMap((group) => group.hooks).filter((hook) =>
      hook.command.includes("/bin/sidekick hook codex")
    ).length,
    1
  );
}
for (const claudeHome of [".claude", ".claude-personal"]) {
  const claudeHooks = JSON.parse(
    fs.readFileSync(path.join(configHome, claudeHome, "settings.json"), "utf8")
  ).hooks;
  for (const eventName of ["SessionStart", "UserPromptSubmit", "Stop"]) {
    assert.equal(
      claudeHooks[eventName].flatMap((group) => group.hooks).filter((hook) =>
        hook.command.includes("/bin/sidekick hook claude")
      ).length,
      1
    );
  }
}
assert.match(
  fs.readFileSync(path.join(configHome, ".hammerspoon", "init.lua"), "utf8"),
  /require\("sidekick-init"\)/
);

console.log("Sidekick tests passed");
