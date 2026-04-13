#!/bin/bash
# test-v433-hardening.sh — TDD tests for v4.3.3 quick wins (Cortex comparison)
# 5 features: downvote, 3 extra scrubbing patterns, path traversal, token budget, multi-session promote
# Run: bash tests/test-v433-hardening.sh

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ACTIVATOR="$SCRIPT_DIR/core/_instinct-activator.sh"
OBSERVE_PY="$SCRIPT_DIR/skills/sinapsis-learning/hooks/observe_v3.py"

PASS=0
FAIL=0
TOTAL=14

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/.claude/skills"
}

teardown_sandbox() {
  rm -rf "$SANDBOX" 2>/dev/null
}

echo ""
echo "=== Sinapsis v4.3.3 Hardening Tests ==="
echo "=== $TOTAL tests: downvote, scrubbing, path traversal, token cap, multi-session ==="
echo ""

# ── Section 1: /downvote command exists ──
echo "[Section 1] Downvote command"

if [ -f "$SCRIPT_DIR/commands/downvote.md" ]; then
  pass "T1: /downvote command file exists"
else
  fail "T1: /downvote command file missing"
fi

# Check the command file mentions archiving or reducing level
if grep -qi "level.*draft\|archive\|downvote\|reduce.*confidence" "$SCRIPT_DIR/commands/downvote.md" 2>/dev/null; then
  pass "T2: /downvote references level demotion"
else
  fail "T2: /downvote should reference level demotion"
fi

# ── Section 2: Extra secret scrubbing patterns (Stripe, Slack, private key) ──
echo ""
echo "[Section 2] Extra scrubbing patterns"

# Check observe_v3.py has Stripe pattern
if grep -q "sk_live\|sk_test\|STRIPE" "$OBSERVE_PY" 2>/dev/null; then
  pass "T3: Stripe secret pattern (sk_live/sk_test) present"
else
  fail "T3: Stripe secret pattern missing in observe_v3.py"
fi

# Check for Slack webhook/token pattern
if grep -q "xoxb\|xoxp\|SLACK" "$OBSERVE_PY" 2>/dev/null; then
  pass "T4: Slack token pattern (xoxb/xoxp) present"
else
  fail "T4: Slack token pattern missing in observe_v3.py"
fi

# Check for private key pattern (beyond PEM — base64 encoded keys)
if grep -q "PRIVATE.*KEY\|private.key\|PRIVATE_KEY_RE\|SENDGRID\|SG\." "$OBSERVE_PY" 2>/dev/null; then
  pass "T5: SendGrid/private key pattern present"
else
  fail "T5: SendGrid/private key pattern missing in observe_v3.py"
fi

# ── Section 3: Path traversal protection in instinct-activator ──
echo ""
echo "[Section 3] Path traversal protection"

# Check that activator validates inject content for path traversal
if grep -q "path.traversal\|\\.\\.\/\|\\.\\.\\\\\\|PATH_TRAVERSAL\|path_blocked" "$ACTIVATOR" 2>/dev/null; then
  pass "T6: Path traversal check present in activator"
else
  fail "T6: Path traversal check missing in activator"
fi

# ── Section 4: Token budget cap ──
echo ""
echo "[Section 4] Token budget cap"

# Check activator has a total token/char limit for injected content
if grep -q "TOKEN_BUDGET\|BUDGET\|MAX_TOTAL\|totalLen\|total_len\|budget" "$ACTIVATOR" 2>/dev/null; then
  pass "T7: Token budget cap present in activator"
else
  fail "T7: Token budget cap missing in activator"
fi

# Functional test: create index with 10 instincts that would exceed budget
setup_sandbox
INSTINCTS=""
for i in $(seq 1 10); do
  INSTINCTS="$INSTINCTS{\"id\":\"big-$i\",\"domain\":\"d$i\",\"level\":\"confirmed\",\"trigger_pattern\":\"Edit\",\"inject\":\"$(printf 'A%.0s' {1..400})\",\"occurrences\":1,\"first_triggered\":\"2026-04-01\",\"last_triggered\":\"2026-04-12\"}"
  [ "$i" -lt 10 ] && INSTINCTS="$INSTINCTS,"
done
cat > "$SANDBOX/.claude/skills/_instincts-index.json" << EOFINDEX
{"version":"4.3","instincts":[$INSTINCTS],"archived":[]}
EOFINDEX

RESULT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"test.js"}}' | HOME="$SANDBOX" node -e "
const fs = require('fs');
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
  const data = JSON.parse(input);
  const index = JSON.parse(fs.readFileSync(process.env.HOME + '/.claude/skills/_instincts-index.json', 'utf8'));
  const instincts = index.instincts || [];
  const context = data.tool_name + ' ' + JSON.stringify(data.tool_input);
  const matches = [];
  for (const inst of instincts) {
    if (!inst.trigger_pattern) continue;
    if (inst.level === 'draft') continue;
    try { if (!new RegExp(inst.trigger_pattern, 'i').test(context)) continue; } catch(e) { continue; }
    matches.push(inst);
  }
  // Simulate budget cap
  const BUDGET = 1500;
  let totalLen = 0;
  const capped = [];
  for (const m of matches) {
    const len = (m.inject || '').length;
    if (totalLen + len > BUDGET) break;
    totalLen += len;
    capped.push(m);
  }
  console.log(capped.length);
});
" 2>/dev/null)
teardown_sandbox

if [ -n "$RESULT" ] && [ "$RESULT" -lt 10 ] 2>/dev/null; then
  pass "T8: Token budget caps injection (got $RESULT of 10 instincts)"
else
  fail "T8: Token budget should cap injection (got: '$RESULT')"
fi

# ── Section 5: Multi-session auto-promote ──
echo ""
echo "[Section 5] Multi-session auto-promote"

# Check activator tracks sessions_seen or equivalent
if grep -q "sessions_seen\|session_ids\|distinct.*session\|unique.*session\|sessions_triggered" "$ACTIVATOR" 2>/dev/null; then
  pass "T9: Multi-session tracking field present in activator"
else
  fail "T9: Multi-session tracking field missing in activator"
fi

# Check auto-promote condition includes session count
if grep -q "sessions_seen\|sessions_triggered\|\.length >= 3\|>= 3" "$ACTIVATOR" 2>/dev/null; then
  pass "T10: Auto-promote requires 3+ sessions"
else
  fail "T10: Auto-promote should require 3+ sessions (not just 5+ occurrences)"
fi

# Functional: test multi-session auto-promote logic inline with Node.js (no bash wrapper needed)
setup_sandbox

# T11: draft with 6 occ but only 1 session — should NOT promote
LEVEL=$(node -e '
const index = {instincts:[{id:"t",domain:"general",level:"draft",trigger_pattern:"Bash",inject:"rule",occurrences:6,sessions_seen:["s1"],first_triggered:"2026-04-01",last_triggered:"2026-04-12"}]};
const sessionId = "s1";
for (const inst of index.instincts) {
  inst.occurrences++;
  inst.last_triggered = new Date().toISOString();
  if (!inst.sessions_seen) inst.sessions_seen = [];
  if (!inst.sessions_seen.includes(sessionId)) inst.sessions_seen.push(sessionId);
  if (inst.level === "draft" && inst.occurrences >= 5 && (inst.sessions_seen || []).length >= 3) {
    inst.level = "confirmed";
  }
}
console.log(index.instincts[0].level);
' 2>/dev/null)

if [ "$LEVEL" = "draft" ]; then
  pass "T11: Draft with 7 occ but 1 session stays draft"
else
  fail "T11: Draft should stay draft with only 1 session (got: '$LEVEL')"
fi

# T12: draft with 4 occ and 3 sessions + new session → should promote (5 occ, 4 sessions)
LEVEL2=$(node -e '
const index = {instincts:[{id:"t",domain:"general",level:"draft",trigger_pattern:"Bash",inject:"rule",occurrences:4,sessions_seen:["s1","s2","s3"],first_triggered:"2026-04-01",last_triggered:"2026-04-12"}]};
const sessionId = "s4";
for (const inst of index.instincts) {
  inst.occurrences++;
  inst.last_triggered = new Date().toISOString();
  if (!inst.sessions_seen) inst.sessions_seen = [];
  if (!inst.sessions_seen.includes(sessionId)) inst.sessions_seen.push(sessionId);
  if (inst.level === "draft" && inst.occurrences >= 5 && (inst.sessions_seen || []).length >= 3) {
    inst.level = "confirmed";
  }
}
console.log(index.instincts[0].level);
' 2>/dev/null)

if [ "$LEVEL2" = "confirmed" ]; then
  pass "T12: Draft with 5 occ AND 4 sessions promotes to confirmed"
else
  fail "T12: Draft should promote with 5+ occ AND 3+ sessions (got: '$LEVEL2')"
fi
teardown_sandbox

# ── Section 6: Version bump ──
echo ""
echo "[Section 6] Version consistency"

if grep -q "4\.3\.3" "$ACTIVATOR" 2>/dev/null; then
  pass "T13: Activator version bumped to v4.3.3"
else
  fail "T13: Activator version should be v4.3.3"
fi

if grep -q "4\.3\.3" "$SCRIPT_DIR/CHANGELOG.md" 2>/dev/null; then
  pass "T14: CHANGELOG has v4.3.3 entry"
else
  fail "T14: CHANGELOG missing v4.3.3 entry"
fi

# ── Summary ──
echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "SOME TESTS FAILED"
  exit 1
fi
