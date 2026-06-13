#!/usr/bin/env node

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const apply = process.argv.includes("--apply");
const profilesOnly = process.argv.includes("--profiles-only");
const home = process.env.HOME || os.homedir();
const sidekickHome = process.env.SIDEKICK_HOME || path.join(home, ".sidekick");
const commandFor = (agent) => `${sidekickHome}/bin/sidekick hook ${agent}`;
const codexEvents = ["SessionStart", "UserPromptSubmit", "Stop"];
const claudeEvents = ["SessionStart", "UserPromptSubmit", "Stop", "PreToolUse"];

function loadJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return {};
    throw error;
  }
}

function configureHooks(file, agent) {
  const data = loadJson(file);
  data.hooks ||= {};
  let changed = false;
  const events = agent === "claude" ? claudeEvents : codexEvents;

  for (const eventName of events) {
    data.hooks[eventName] ||= [];
    const command = commandFor(agent);
    const exists = data.hooks[eventName].some((group) =>
      Array.isArray(group.hooks) && group.hooks.some((hook) => hook.command === command)
    );
    if (!exists) {
      data.hooks[eventName].push({
        hooks: [{ type: "command", command, timeout: 3 }]
      });
      changed = true;
    }
  }

  if (apply && changed) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    if (fs.existsSync(file)) fs.copyFileSync(file, `${file}.sidekick-backup`);
    fs.writeFileSync(file, `${JSON.stringify(data, null, 2)}\n`);
  }
  return changed;
}

function configureHammerspoon(file) {
  const marker = 'require("sidekick-init")';
  let content = "";
  try {
    content = fs.readFileSync(file, "utf8");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  if (content.includes(marker)) return false;

  const legacy = 'require("sidekick").start()';
  const withoutLegacy = content
    .split("\n")
    .filter((line) => line.trim() !== legacy)
    .join("\n")
    .trimEnd();
  const next = `${withoutLegacy}${withoutLegacy ? "\n\n" : ""}${marker}\n`;
  if (apply) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    if (fs.existsSync(file)) fs.copyFileSync(file, `${file}.sidekick-backup`);
    fs.writeFileSync(file, next);
  }
  return true;
}

function discoverCodexHomes() {
  let discovered = [];
  try {
    discovered = fs
      .readdirSync(home, { withFileTypes: true })
      .filter((entry) => entry.isDirectory() && /^\.codex(?:-.+)?$/.test(entry.name))
      .map((entry) => path.join(home, entry.name))
      .filter((directory) => fs.existsSync(path.join(directory, "config.toml")));
  } catch {
    discovered = [];
  }
  return [process.env.CODEX_HOME, path.join(home, ".codex"), ...discovered]
    .filter(Boolean)
    .filter((value, index, values) => values.indexOf(value) === index)
    .filter((value) => value === process.env.CODEX_HOME || fs.existsSync(value));
}

function discoverClaudeHomes() {
  let discovered = [];
  try {
    discovered = fs
      .readdirSync(home, { withFileTypes: true })
      .filter((entry) => entry.isDirectory() && /^\.claude(?:-.+)?$/.test(entry.name))
      .map((entry) => path.join(home, entry.name))
      .filter((directory) => fs.existsSync(path.join(directory, "settings.json")));
  } catch {
    discovered = [];
  }
  return [process.env.CLAUDE_CONFIG_DIR, path.join(home, ".claude"), ...discovered]
    .filter(Boolean)
    .filter((value, index, values) => values.indexOf(value) === index)
    .filter((value) => value === process.env.CLAUDE_CONFIG_DIR || fs.existsSync(value));
}

const codexHomes = discoverCodexHomes()
  .filter(Boolean)
  .sort();
const claudeHomes = discoverClaudeHomes()
  .filter(Boolean)
  .sort();

const changes = [
  ...codexHomes.map((codexHome) => {
    const file = path.join(codexHome, "hooks.json");
    return {
      name: `Codex hooks (${codexHome})`,
      file,
      changed: configureHooks(file, "codex")
    };
  }),
  ...claudeHomes.map((claudeHome) => {
    const file = path.join(claudeHome, "settings.json");
    return {
      name: `Claude hooks (${claudeHome})`,
      file,
      changed: configureHooks(file, "claude")
    };
  }),
  ...(profilesOnly
    ? []
    : [
        {
          name: "Hammerspoon init",
          file: path.join(home, ".hammerspoon", "init.lua"),
          changed: configureHammerspoon(path.join(home, ".hammerspoon", "init.lua"))
        }
      ])
];

for (const item of changes) {
  const state = item.changed ? (apply ? "configured" : "missing") : "connected";
  console.log(`${item.name}: ${state} (${item.file})`);
}
