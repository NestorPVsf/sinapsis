#!/bin/bash
# TDD tests for _reflection-orchestrator.sh
# Tests the deterministic logic: guards, budget checks, proposal counting, merge logic.
# Does NOT test actual claude CLI calls (those are integration tests).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
ORCH_SCRIPT="$REPO_DIR/core/_reflection-orchestrator.sh"

PASS=0
FAIL=0
TOTAL=0

# Setup sandbox
SANDBOX=$(mktemp -d)
export HOME="$SANDBOX"
SKILLS_DIR="$SANDBOX/.claude/skills"
mkdir -p "$SKILLS_DIR"

cleanup() {
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

assert_eq() {
  TOTAL=$((TOTAL + 1))
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected='$expected', got='$actual')"
  fi
}

assert_file_exists() {
  TOTAL=$((TOTAL + 1))
  local desc="$1" path="$2"
  if [ -f "$path" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (file not found: $path)"
  fi
}

assert_file_not_exists() {
  TOTAL=$((TOTAL + 1))
  local desc="$1" path="$2"
  if [ ! -f "$path" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (file should not exist: $path)"
  fi
}

assert_file_contains() {
  TOTAL=$((TOTAL + 1))
  local desc="$1" path="$2" pattern="$3"
  if grep -q "$pattern" "$path" 2>/dev/null; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (pattern '$pattern' not found in $path)"
  fi
}

reset_sandbox() {
  rm -rf "$SKILLS_DIR"
  mkdir -p "$SKILLS_DIR"
}

echo "============================================"
echo "  Reflection Orchestrator — TDD Tests"
echo "============================================"
echo ""

# ── Test 1: Exits cleanly when no proposals file exists ──
echo "[Test 1] No proposals file → exit 0"
reset_sandbox
bash "$ORCH_SCRIPT" 2>/dev/null
assert_eq "exits without error" "0" "$?"
assert_file_not_exists "no log created" "$SKILLS_DIR/_reflection-log.jsonl"

# ── Test 2: Exits when proposals file is empty ──
echo "[Test 2] Empty proposals → exit 0"
reset_sandbox
echo '{"version":"2.0","session_date":"2026-04-08","proposals":[]}' > "$SKILLS_DIR/_instinct-proposals.json"
bash "$ORCH_SCRIPT" 2>/dev/null
assert_eq "exits without error" "0" "$?"

# ── Test 3: Exits when all proposals already classified ──
echo "[Test 3] All proposals classified → exit 0"
reset_sandbox
cat > "$SKILLS_DIR/_instinct-proposals.json" <<'EOF'
{
  "version": "2.0",
  "session_date": "2026-04-08",
  "proposals": [
    {
      "id": "fix-bash",
      "type": "error_resolution",
      "scout_classification": "low_signal"
    }
  ]
}
EOF
bash "$ORCH_SCRIPT" 2>/dev/null
assert_eq "exits without error" "0" "$?"

# ── Test 4: Detects unclassified proposals ──
echo "[Test 4] Unclassified proposals detected"
reset_sandbox
cat > "$SKILLS_DIR/_instinct-proposals.json" <<'EOF'
{
  "version": "2.0",
  "session_date": "2026-04-08",
  "proposals": [
    {
      "id": "fix-bash",
      "type": "error_resolution",
      "status": "pending"
    },
    {
      "id": "correction-readme",
      "type": "user_correction",
      "status": "pending"
    }
  ]
}
EOF
# This will either:
# a) fail at claude CLI check (not installed) → logs orchestrator_skip
# b) claude exists but scout prompt missing → logs scout_skip
bash "$ORCH_SCRIPT" 2>/dev/null || true
if [ -f "$SKILLS_DIR/_reflection-log.jsonl" ]; then
  # Either orchestrator_skip (no claude) or scout_skip (no prompt) is valid
  HAS_SKIP=$(grep -c "skip" "$SKILLS_DIR/_reflection-log.jsonl" 2>/dev/null || echo "0")
  assert_eq "logged a skip event" "1" "$([ "$HAS_SKIP" -gt 0 ] && echo 1 || echo 0)"
  assert_eq "log file has content" "1" "$([ -s "$SKILLS_DIR/_reflection-log.jsonl" ] && echo 1 || echo 0)"
else
  # No log means something unexpected — fail
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: no log file created"
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: expected log content"
fi

# ── Test 5: Budget check — within limits ──
echo "[Test 5] Budget check — under limit returns 1"
reset_sandbox
cat > "$SKILLS_DIR/_agent-budget.json" <<'EOF'
{
  "version": "1.0",
  "daily_limits": { "scout": { "max_calls": 50 }, "analyst": { "max_calls": 10 } },
  "usage": {}
}
EOF
RESULT=$(node -e '
  const fs = require("fs");
  const today = new Date().toISOString().slice(0, 10);
  const b = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const limit = (b.daily_limits || {})["scout"] || { max_calls: 999 };
  const usage = ((b.usage || {})[today] || {})["scout"] || { calls: 0 };
  console.log(usage.calls < limit.max_calls ? "1" : "0");
' "$SKILLS_DIR/_agent-budget.json" 2>/dev/null)
assert_eq "budget allows scout" "1" "$RESULT"

# ── Test 6: Budget check — over limit ──
echo "[Test 6] Budget check — over limit returns 0"
TODAY=$(date -u +"%Y-%m-%d")
cat > "$SKILLS_DIR/_agent-budget.json" <<EOF
{
  "version": "1.0",
  "daily_limits": { "scout": { "max_calls": 2 } },
  "usage": { "$TODAY": { "scout": { "calls": 5, "tokens": 1000 } } }
}
EOF
RESULT=$(node -e '
  const fs = require("fs");
  const today = new Date().toISOString().slice(0, 10);
  const b = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const limit = (b.daily_limits || {})["scout"] || { max_calls: 999 };
  const usage = ((b.usage || {})[today] || {})["scout"] || { calls: 0 };
  console.log(usage.calls < limit.max_calls ? "1" : "0");
' "$SKILLS_DIR/_agent-budget.json" 2>/dev/null)
assert_eq "budget blocks scout" "0" "$RESULT"

# ── Test 7: Budget recording — increments calls ──
echo "[Test 7] Budget recording increments usage"
reset_sandbox
cat > "$SKILLS_DIR/_agent-budget.json" <<'EOF'
{ "version": "1.0", "daily_limits": {}, "usage": {} }
EOF
node -e '
  const fs = require("fs");
  const budgetFile = process.argv[1];
  const agent = "scout";
  const today = new Date().toISOString().slice(0, 10);
  let b = JSON.parse(fs.readFileSync(budgetFile, "utf8"));
  if (!b.usage) b.usage = {};
  if (!b.usage[today]) b.usage[today] = {};
  if (!b.usage[today][agent]) b.usage[today][agent] = { calls: 0, tokens: 0 };
  b.usage[today][agent].calls++;
  fs.writeFileSync(budgetFile, JSON.stringify(b, null, 2));
' "$SKILLS_DIR/_agent-budget.json" 2>/dev/null
CALLS=$(node -e '
  const fs = require("fs");
  const b = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const today = new Date().toISOString().slice(0, 10);
  console.log(((b.usage || {})[today] || {}).scout?.calls || 0);
' "$SKILLS_DIR/_agent-budget.json" 2>/dev/null)
assert_eq "calls incremented to 1" "1" "$CALLS"

# ── Test 8: Scout merge logic — classifications applied ──
echo "[Test 8] Scout merge applies classifications to proposals"
reset_sandbox
cat > "$SKILLS_DIR/_instinct-proposals.json" <<'EOF'
{
  "version": "2.0",
  "session_date": "2026-04-08",
  "proposals": [
    { "id": "fix-bash", "type": "error_resolution", "status": "pending" },
    { "id": "correction-readme", "type": "user_correction", "status": "pending" }
  ]
}
EOF
# Simulate Scout output merge
node -e '
  const fs = require("fs");
  const proposals = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const scout = [
    { id: "fix-bash", classification: "high_signal", tags: ["error-gotcha"], needs_analyst: true, reason: "Error pattern" },
    { id: "correction-readme", classification: "noise", tags: [], needs_analyst: false, reason: "Single edit" }
  ];
  const now = new Date().toISOString();
  for (const c of scout) {
    const p = proposals.proposals.find(x => x.id === c.id);
    if (p) {
      p.scout_classification = c.classification;
      p.scout_tags = c.tags;
      p.needs_analyst = c.needs_analyst;
      p.scout_reason = c.reason;
      p.scout_at = now;
    }
  }
  fs.writeFileSync(process.argv[1], JSON.stringify(proposals, null, 2));
' "$SKILLS_DIR/_instinct-proposals.json" 2>/dev/null

# Verify
CLASSIFIED=$(node -e '
  const fs = require("fs");
  const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const classified = p.proposals.filter(x => x.scout_classification);
  console.log(classified.length);
' "$SKILLS_DIR/_instinct-proposals.json" 2>/dev/null)
assert_eq "2 proposals classified" "2" "$CLASSIFIED"

HIGH=$(node -e '
  const fs = require("fs");
  const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const high = p.proposals.filter(x => x.scout_classification === "high_signal");
  console.log(high.length);
' "$SKILLS_DIR/_instinct-proposals.json" 2>/dev/null)
assert_eq "1 high_signal" "1" "$HIGH"

NEEDS=$(node -e '
  const fs = require("fs");
  const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const needs = p.proposals.filter(x => x.needs_analyst);
  console.log(needs.length);
' "$SKILLS_DIR/_instinct-proposals.json" 2>/dev/null)
assert_eq "1 needs analyst" "1" "$NEEDS"

# ── Test 9: Budget pruning — removes entries older than 30 days ──
echo "[Test 9] Budget prunes old entries"
reset_sandbox
cat > "$SKILLS_DIR/_agent-budget.json" <<'EOF'
{
  "version": "1.0",
  "daily_limits": {},
  "usage": {
    "2020-01-01": { "scout": { "calls": 5, "tokens": 1000 } },
    "2020-06-15": { "analyst": { "calls": 2, "tokens": 500 } }
  }
}
EOF
node -e '
  const fs = require("fs");
  const budgetFile = process.argv[1];
  const today = new Date().toISOString().slice(0, 10);
  let b = JSON.parse(fs.readFileSync(budgetFile, "utf8"));
  if (!b.usage[today]) b.usage[today] = {};
  if (!b.usage[today]["scout"]) b.usage[today]["scout"] = { calls: 0, tokens: 0 };
  b.usage[today]["scout"].calls++;
  const cutoff = new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10);
  for (const d of Object.keys(b.usage)) { if (d < cutoff) delete b.usage[d]; }
  fs.writeFileSync(budgetFile, JSON.stringify(b, null, 2));
' "$SKILLS_DIR/_agent-budget.json" 2>/dev/null

KEYS=$(node -e '
  const b = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  console.log(Object.keys(b.usage).length);
' "$SKILLS_DIR/_agent-budget.json" 2>/dev/null)
assert_eq "old entries pruned, only today remains" "1" "$KEYS"

# ── Test 10: Template files have correct schema ──
echo "[Test 10] Template files validate"
for tpl in _knowledge-graph.json _agent-budget.json _instinct-proposals.json; do
  TPL_FILE="$REPO_DIR/core/$tpl"
  if [ -f "$TPL_FILE" ]; then
    VALID=$(node -e 'try { JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); console.log("1"); } catch(e) { console.log("0"); }' "$TPL_FILE" 2>/dev/null)
    assert_eq "$tpl is valid JSON" "1" "$VALID"
  else
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    echo "  FAIL: $tpl not found"
  fi
done

# ── Results ──
echo ""
echo "============================================"
echo "  Results: $PASS/$TOTAL passed ($FAIL failed)"
echo "============================================"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
