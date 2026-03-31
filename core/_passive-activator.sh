#!/bin/bash
# Passive Activator - Sinapsis v4.1
# PreToolUse hook (sync, 5s): reads _passive-rules.json, matches trigger regex
# against current tool+input, injects matched rules as systemMessage.
# Only matched rules are injected (~20-80 tokens per tool use).

RULES="$HOME/.claude/skills/_passive-rules.json"
[ ! -f "$RULES" ] && exit 0

node -e '
const fs = require("fs");

let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  let data;
  try { data = JSON.parse(input); } catch(e) { process.exit(0); }

  let cfg;
  try { cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch(e) { process.exit(0); }

  const rules = cfg.rules || [];
  if (rules.length === 0) process.exit(0);

  // Build context string from tool name + input fields
  const tool = data.tool_name || "";
  let inputContent = "";
  try {
    const inp = data.tool_input || {};
    inputContent = [inp.command, inp.file_path, inp.pattern, inp.prompt, inp.content]
      .filter(Boolean).join(" ").slice(0, 500);
  } catch(e) {}
  const context = tool + " " + inputContent;

  // Match rules: test trigger regex against context
  const matched = [];
  for (const rule of rules) {
    if (!rule.trigger || !rule.inject) continue;
    // EVERY_SESSION rules always fire
    if (rule.trigger === "EVERY_SESSION") {
      matched.push(rule.inject);
      continue;
    }
    try {
      if (new RegExp(rule.trigger, "i").test(context)) {
        matched.push(rule.inject);
      }
    } catch(e) { continue; }
  }

  if (matched.length === 0) process.exit(0);

  // Cap at 3 rules to avoid token bloat
  const top = matched.slice(0, 3);
  console.log(JSON.stringify({ systemMessage: top.join("\n") }));
});
' "$RULES" 2>/dev/null

exit 0
