#!/bin/bash
# Reflection Orchestrator - Sinapsis v5.0
# Deterministic script (NO LLM calls in this file).
# Decides which reflection agents to invoke based on proposal state.
# Called by _session-learner.sh in background after pattern detection.
#
# Flow:
#   1. Read _instinct-proposals.json
#   2. Count unclassified proposals
#   3. If any: invoke Scout (Haiku) for triage
#   4. If Scout escalates: invoke Analyst (Sonnet) if budget allows
#   5. Log all decisions to _reflection-log.jsonl

set -e

SKILLS_DIR="$HOME/.claude/skills"
PROPOSALS_FILE="$SKILLS_DIR/_instinct-proposals.json"
BUDGET_FILE="$SKILLS_DIR/_agent-budget.json"
LOG_FILE="$SKILLS_DIR/_reflection-log.jsonl"
INDEX_FILE="$SKILLS_DIR/_instincts-index.json"
SCOUT_PROMPT="$SKILLS_DIR/_agent-scout.prompt.md"
ANALYST_PROMPT="$SKILLS_DIR/_agent-analyst.prompt.md"

# v5: SINAPSIS_DEBUG mode
if [ "${SINAPSIS_DEBUG:-}" = "1" ]; then
  exec 2>>"$SKILLS_DIR/_sinapsis-debug.log"
fi

# ── Guard: proposals file must exist and have pending items ──
[ ! -f "$PROPOSALS_FILE" ] && exit 0

# Count unclassified proposals (no scout_classification field)
PENDING_COUNT=$(node -e '
  try {
    const fs = require("fs");
    const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const pending = (p.proposals || []).filter(x => !x.scout_classification);
    console.log(pending.length);
  } catch(e) { console.log("0"); }
' "$PROPOSALS_FILE" 2>/dev/null)

if [ "$PENDING_COUNT" = "0" ] || [ -z "$PENDING_COUNT" ]; then
  exit 0
fi

# ── Guard: claude CLI must be available ──
if ! command -v claude >/dev/null 2>&1; then
  # Log that agents are unavailable
  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
  echo "{\"timestamp\":\"$NOW\",\"event\":\"orchestrator_skip\",\"reason\":\"claude_cli_not_found\",\"pending\":$PENDING_COUNT}" >> "$LOG_FILE" 2>/dev/null
  exit 0
fi

# ── Budget check helper ──
check_budget() {
  local agent="$1"
  node -e '
    const fs = require("fs");
    const budgetFile = process.argv[1];
    const agent = process.argv[2];
    const today = new Date().toISOString().slice(0, 10);
    try {
      const b = JSON.parse(fs.readFileSync(budgetFile, "utf8"));
      const limit = (b.daily_limits || {})[agent] || { max_calls: 999 };
      const usage = ((b.usage || {})[today] || {})[agent] || { calls: 0 };
      console.log(usage.calls < limit.max_calls ? "1" : "0");
    } catch(e) { console.log("1"); } // no budget file = no limit
  ' "$BUDGET_FILE" "$agent" 2>/dev/null
}

# ── Record cost helper ──
record_usage() {
  local agent="$1"
  local tokens="$2"
  node -e '
    const fs = require("fs");
    const budgetFile = process.argv[1];
    const agent = process.argv[2];
    const tokens = parseInt(process.argv[3]) || 0;
    const today = new Date().toISOString().slice(0, 10);
    let b;
    try { b = JSON.parse(fs.readFileSync(budgetFile, "utf8")); } catch(e) {
      b = { version: "1.0", daily_limits: {}, usage: {} };
    }
    if (!b.usage) b.usage = {};
    if (!b.usage[today]) b.usage[today] = {};
    if (!b.usage[today][agent]) b.usage[today][agent] = { calls: 0, tokens: 0 };
    b.usage[today][agent].calls++;
    b.usage[today][agent].tokens += tokens;
    // Prune usage older than 30 days
    const cutoff = new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10);
    for (const d of Object.keys(b.usage)) {
      if (d < cutoff) delete b.usage[d];
    }
    const tmp = budgetFile + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(b, null, 2));
    fs.renameSync(tmp, budgetFile);
  ' "$BUDGET_FILE" "$agent" "$tokens" 2>/dev/null
}

# ── Log helper ──
log_event() {
  local event="$1"
  local detail="$2"
  local NOW
  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
  echo "{\"timestamp\":\"$NOW\",\"event\":\"$event\",\"detail\":\"$detail\"}" >> "$LOG_FILE" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════
# STAGE 1: SCOUT (Haiku) — always run if proposals pending
# ══════════════════════════════════════════════════════════════

SCOUT_BUDGET_OK=$(check_budget scout)
if [ "$SCOUT_BUDGET_OK" != "1" ]; then
  log_event "scout_skip" "daily budget exceeded"
  exit 0
fi

if [ ! -f "$SCOUT_PROMPT" ]; then
  log_event "scout_skip" "prompt file missing"
  exit 0
fi

# Build Scout input: proposals + existing instinct summaries
SCOUT_INPUT=$(node -e '
  const fs = require("fs");
  const proposals = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const pending = proposals.proposals.filter(x => !x.scout_classification);
  let existingSummary = [];
  try {
    const idx = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
    existingSummary = (idx.instincts || []).map(i => ({ id: i.id, domain: i.domain, inject: (i.inject || "").slice(0, 100) }));
  } catch(e) {}
  console.log(JSON.stringify({ pending_proposals: pending, existing_instincts: existingSummary }));
' "$PROPOSALS_FILE" "$INDEX_FILE" 2>/dev/null)

if [ -z "$SCOUT_INPUT" ]; then
  log_event "scout_error" "failed to build input"
  exit 0
fi

# Invoke Scout via claude CLI
SCOUT_OUTPUT=$(echo "$SCOUT_INPUT" | claude --model haiku --print \
  --system-prompt "$(cat "$SCOUT_PROMPT")" \
  --max-tokens 2000 2>/dev/null) || true

if [ -n "$SCOUT_OUTPUT" ]; then
  # Merge Scout output into proposals
  MERGE_OK=$(node -e '
    const fs = require("fs");
    try {
      const proposals = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const scout = JSON.parse(process.argv[2]);
      const classifications = Array.isArray(scout) ? scout : (scout.classifications || scout.results || []);
      const now = new Date().toISOString();
      for (const c of classifications) {
        const p = proposals.proposals.find(x => x.id === c.id);
        if (p) {
          p.scout_classification = c.classification || "low_signal";
          p.scout_tags = c.tags || [];
          p.needs_analyst = !!c.needs_analyst;
          p.scout_reason = (c.reason || "").slice(0, 200);
          p.scout_duplicate_of = c.duplicate_of || null;
          p.scout_at = now;
        }
      }
      const tmp = process.argv[1] + ".tmp";
      fs.writeFileSync(tmp, JSON.stringify(proposals, null, 2));
      fs.renameSync(tmp, process.argv[1]);
      // Count escalations
      const escalated = proposals.proposals.filter(x => x.needs_analyst || x.scout_classification === "high_signal");
      console.log(escalated.length);
    } catch(e) { console.log("0"); }
  ' "$PROPOSALS_FILE" "$SCOUT_OUTPUT" 2>/dev/null)

  record_usage scout 0
  log_event "scout_complete" "$PENDING_COUNT proposals triaged, $MERGE_OK escalated"
else
  log_event "scout_error" "empty output from claude"
  exit 0
fi

# ══════════════════════════════════════════════════════════════
# STAGE 2: ANALYST (Sonnet) — only if Scout escalated
# ══════════════════════════════════════════════════════════════

NEEDS_ANALYST="${MERGE_OK:-0}"

if [ "$NEEDS_ANALYST" -gt 0 ] 2>/dev/null; then
  ANALYST_BUDGET_OK=$(check_budget analyst)
  if [ "$ANALYST_BUDGET_OK" != "1" ]; then
    log_event "analyst_skip" "daily budget exceeded"
    exit 0
  fi

  if [ ! -f "$ANALYST_PROMPT" ]; then
    log_event "analyst_skip" "prompt file missing"
    exit 0
  fi

  # Build Analyst input: escalated proposals + full index + context
  ANALYST_INPUT=$(node -e '
    const fs = require("fs");
    const proposals = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const escalated = proposals.proposals.filter(x => x.needs_analyst || x.scout_classification === "high_signal");
    let index = { instincts: [] };
    try { index = JSON.parse(fs.readFileSync(process.argv[2], "utf8")); } catch(e) {}
    console.log(JSON.stringify({
      escalated_proposals: escalated,
      instincts_index: { count: (index.instincts || []).length, instincts: (index.instincts || []).slice(0, 50) }
    }));
  ' "$PROPOSALS_FILE" "$INDEX_FILE" 2>/dev/null)

  ANALYST_OUTPUT=$(echo "$ANALYST_INPUT" | claude --model sonnet --print \
    --system-prompt "$(cat "$ANALYST_PROMPT")" \
    --max-tokens 4000 2>/dev/null) || true

  if [ -n "$ANALYST_OUTPUT" ]; then
    # Merge Analyst output into proposals
    node -e '
      const fs = require("fs");
      try {
        const proposals = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        const analyst = JSON.parse(process.argv[2]);
        const analyses = Array.isArray(analyst) ? analyst : (analyst.analyses || analyst.results || []);
        const now = new Date().toISOString();
        for (const a of analyses) {
          const p = proposals.proposals.find(x => x.id === a.id);
          if (p) {
            p.analyst_score = a.score || {};
            p.analyst_enrichment = a.enrichment || null;
            p.analyst_decision = a.decision || "queue";
            p.analyst_at = now;
          }
        }
        const tmp = process.argv[1] + ".tmp";
        fs.writeFileSync(tmp, JSON.stringify(proposals, null, 2));
        fs.renameSync(tmp, process.argv[1]);
      } catch(e) {}
    ' "$PROPOSALS_FILE" "$ANALYST_OUTPUT" 2>/dev/null

    record_usage analyst 0
    log_event "analyst_complete" "$NEEDS_ANALYST proposals analyzed"
  else
    log_event "analyst_error" "empty output from claude"
  fi
fi

exit 0
