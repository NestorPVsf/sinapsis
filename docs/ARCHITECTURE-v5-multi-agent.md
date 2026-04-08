# Sinapsis v5 — Multi-Agent Architecture Design

**Author**: Luis Salgado + Claude Opus 4.6
**Date**: 2026-04-08
**Status**: DESIGN (pre-implementation)
**Prerequisite**: Directory audit cleanup applied (see audit report same date)

---

## 1. Problem Statement

Sinapsis v4.3 session-learner is deterministic-only (regex). It detects 3 simple patterns:

| Pattern | What it catches | What it misses |
|---------|----------------|----------------|
| error-fix | Tool X error → Tool X success within 5 events | Root cause, fix quality, whether the fix is generalizable |
| user-corrections | Same file edited 2+ times in 10-event window | Why the correction happened, what preference it reveals |
| workflow-chains | Same 3-tool trigram appears 2+ times | Whether the chain is intentional workflow or coincidence |

**Fundamental limitation**: regex detects _structure_ but not _meaning_. A user correcting variable naming 3 times reveals a style preference that regex can't extract. An error-fix cycle where the user tried 4 different approaches reveals a gotcha worth documenting — but the learner only sees "error then success."

---

## 2. Design Principles

1. **Deterministic runtime, intelligent reflection**. Hooks that fire on every tool use (PreToolUse, PostToolUse, Stop) MUST remain deterministic — no LLM calls in the hot path. LLM analysis runs asynchronously, offline, or on-demand.

2. **Cheap is fast, expensive is deep**. Use the cheapest model that can do the job. Regex > Haiku > Sonnet > Opus. Escalate only when the cheaper layer signals uncertainty.

3. **File-based IPC**. Agents communicate via JSON/JSONL files on disk. No sockets, no RPC, no daemons. This is a CLI plugin, not a microservice.

4. **Backwards compatible**. v5 agents extend the existing pipeline — they don't replace it. The deterministic session-learner continues to run. Agents add a layer of semantic analysis on top.

5. **Token-conscious**. Every LLM call has a budget. Opus calls are expensive — they must justify their cost with high-quality analysis that the user couldn't get otherwise.

---

## 3. Agent Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        RUNTIME (hot path)                          │
│  Same as v4.3 — deterministic, no LLM calls                       │
│                                                                     │
│  PreToolUse:  observe.sh → observe_v3.py (JSONL logging)           │
│               _passive-activator.sh (rule injection)               │
│               _instinct-activator.sh (instinct injection)          │
│               _project-context.sh (session bridge)                 │
│  PostToolUse: observe.sh → observe_v3.py (JSONL logging)           │
│  Stop:        _session-learner.sh (3 deterministic patterns)       │
│                                                                     │
│  OUTPUT → observations.jsonl, context.md, _instinct-proposals.json │
└────────────────────────┬────────────────────────────────────────────┘
                         │
                         │  files on disk (IPC)
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    REFLECTION LAYER (async)                         │
│  Runs AFTER session ends, or on-demand via /analyze-session        │
│                                                                     │
│  ┌──────────────┐  ┌──────────────────┐  ┌────────────────────┐   │
│  │  SCOUT       │  │  ANALYST         │  │  ARCHITECT         │   │
│  │  (Haiku)     │  │  (Sonnet)        │  │  (Opus)            │   │
│  │              │  │                  │  │                    │   │
│  │  Triage +    │  │  Semantic        │  │  Deep synthesis    │   │
│  │  classify    │  │  scoring +       │  │  + contradiction   │   │
│  │  proposals   │  │  dedup +         │  │  resolution +      │   │
│  │              │  │  enrichment      │  │  meta-learning     │   │
│  │  Cost: ~$0   │  │                  │  │                    │   │
│  │  Speed: <2s  │  │  Cost: ~$0.01    │  │  Cost: ~$0.10      │   │
│  │              │  │  Speed: ~5s      │  │  Speed: ~15s       │   │
│  └──────┬───────┘  └───────┬──────────┘  └─────────┬──────────┘   │
│         │                  │                        │              │
│         │  proposals.json  │  scored.json           │  decisions   │
│         ▼                  ▼                        ▼              │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                    ORCHESTRATOR                               │  │
│  │  _reflection-orchestrator.sh                                 │  │
│  │  Decides: which agent(s) to invoke, in what order            │  │
│  │  Escalation: Scout only → Scout+Analyst → all three          │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
                         │
                         │  writes to
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    KNOWLEDGE STORE (shared state)                   │
│                                                                     │
│  _instincts-index.json     ← confirmed instincts (runtime reads)   │
│  _instinct-proposals.json  ← pending proposals (agents write)      │
│  _reflection-log.jsonl     ← audit trail of agent decisions        │
│  _knowledge-graph.json     ← NEW: relationships between instincts  │
│  _agent-budget.json        ← NEW: token/cost tracking per agent    │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 4. Agent Specifications

### 4.1 SCOUT (Haiku — triage + classification)

**When activated**: Automatically after _session-learner.sh runs (Stop hook chain).

**Input**:
- `_instinct-proposals.json` (raw proposals from deterministic learner)
- Last 200 lines of `observations.jsonl` (recent session context)

**Job**:
1. Classify each proposal: `high_signal` | `low_signal` | `noise`
2. Tag proposals with semantic categories: `style-preference`, `error-gotcha`, `workflow-pattern`, `tooling-gap`, `architecture-decision`
3. Detect proposals that duplicate existing instincts by _meaning_ (not just regex)
4. Flag proposals that need Analyst review (ambiguous, multi-faceted)

**Output**: Updates `_instinct-proposals.json` with `scout_classification`, `scout_tags`, `needs_analyst` fields.

**Prompt template**:
```
You are a triage agent for a developer learning system. Given these raw
pattern proposals detected from a coding session, classify each one.

PROPOSALS:
{{proposals_json}}

EXISTING INSTINCTS (for dedup):
{{existing_instinct_ids_and_descriptions}}

RECENT CONTEXT (last 200 observations):
{{observations_summary}}

For each proposal, output JSON:
{
  "id": "...",
  "classification": "high_signal|low_signal|noise",
  "tags": ["style-preference", ...],
  "needs_analyst": true|false,
  "reason": "one sentence",
  "duplicate_of": "existing-instinct-id or null"
}
```

**Cost control**: Haiku is essentially free. Run on every session that produces proposals.

---

### 4.2 ANALYST (Sonnet — semantic scoring + enrichment)

**When activated**: Only when Scout flags `needs_analyst: true` OR when `/analyze-session` is explicitly invoked.

**Input**:
- Scout-classified proposals (only `high_signal` + `needs_analyst`)
- Full `observations.jsonl` for the session (not truncated)
- `_instincts-index.json` (full knowledge base)
- `context.md` for the project

**Job**:
1. **Semantic scoring**: Rate each proposal 0-100 on:
   - Generalizability (is this project-specific or universal?)
   - Actionability (can Claude act on this without ambiguity?)
   - Novelty (does it add information beyond existing instincts?)
   - Evidence strength (how clear is the observation data?)
2. **Enrichment**: For proposals scoring > 60, generate:
   - A proper `inject` text (what Claude should know when this triggers)
   - A proper `trigger_pattern` regex (what context should activate it)
   - A `domain` classification
   - Suggested `level`: draft vs confirmed (based on evidence strength)
3. **Dedup resolution**: For proposals Scout flagged as potential duplicates, decide:
   - Merge into existing instinct (update inject text)
   - Keep separate (different enough)
   - Discard (true duplicate)

**Output**: Updates `_instinct-proposals.json` with `analyst_score`, `analyst_enrichment`, `analyst_decision` fields.

**Prompt template**:
```
You are a knowledge analyst for a developer learning system. Your job is
to evaluate pattern proposals and decide which ones become permanent
knowledge.

HIGH-SIGNAL PROPOSALS FROM SCOUT:
{{scout_filtered_proposals}}

FULL SESSION OBSERVATIONS:
{{observations_jsonl_summary}}

EXISTING KNOWLEDGE BASE ({{count}} instincts):
{{instincts_index_summary}}

PROJECT CONTEXT:
{{context_md}}

For each proposal:
1. Score 0-100 on generalizability, actionability, novelty, evidence
2. If total score > 60, generate enrichment:
   - inject: "what Claude should remember" (max 300 chars)
   - trigger_pattern: regex that fires on relevant tool contexts
   - domain: one of [general, git, security, frontend, database, ...]
3. Decision: promote | merge:existing-id | discard
4. Reasoning: 2 sentences max
```

**Cost control**: ~$0.01 per invocation. Only runs when Scout escalates.

---

### 4.3 ARCHITECT (Opus — deep synthesis + meta-learning)

**When activated**: Only via explicit `/reflect` command OR when the dream cycle detects systemic issues (>5 contradictions, >10 stale instincts, cluster of related proposals).

**Input**:
- Full `_instincts-index.json`
- `_knowledge-graph.json` (relationships between instincts)
- `_reflection-log.jsonl` (history of past agent decisions)
- All `context.md` across projects
- `_operator-state.json` (strategic decisions)

**Job**:
1. **Contradiction resolution**: Find instincts that conflict and decide which takes priority. Example: "always use try/catch" vs "don't add error handling for internal code" — Architect resolves by adding scope conditions.
2. **Knowledge synthesis**: Detect clusters of related instincts that should be merged into a higher-level principle. Example: 5 instincts about Supabase auth → one "supabase-auth-gates" meta-instinct.
3. **Blind spot detection**: Analyze observation patterns that NO instinct covers. What is the system failing to learn from?
4. **Meta-learning**: Review the reflection log to improve the Scout and Analyst prompts. Are they classifying correctly? Are their scores calibrated?
5. **Skill evolution proposals**: Recommend which instinct clusters should become skills (input for /evolve).

**Output**:
- `_reflection-report.md` (human-readable analysis)
- Updates to `_instincts-index.json` (contradiction resolutions, merges)
- Updates to `_knowledge-graph.json` (new relationships)
- `_architect-recommendations.json` (meta-learning suggestions)

**Cost control**: ~$0.10 per invocation. Maximum 1x per week unless explicitly triggered. The dream cycle can trigger it if systemic issues detected, but caps at 1 invocation per 7 days.

---

## 5. Orchestrator Logic

`_reflection-orchestrator.sh` — a deterministic bash script (no LLM) that decides what to run.

```bash
#!/bin/bash
# Reflection Orchestrator - Sinapsis v5
# Decides which reflection agents to invoke based on proposal state

PROPOSALS="$HOME/.claude/skills/_instinct-proposals.json"
BUDGET="$HOME/.claude/skills/_agent-budget.json"

# Read proposals
PROPOSAL_COUNT=$(node -e "
  const p = JSON.parse(require('fs').readFileSync('$PROPOSALS','utf8'));
  const pending = (p.proposals||[]).filter(x => !x.scout_classification);
  console.log(pending.length);
" 2>/dev/null)

[ "$PROPOSAL_COUNT" = "0" ] && exit 0

# STAGE 1: Always run Scout (Haiku — free)
claude --model haiku --print \
  --system-prompt "$(cat $SCOUT_PROMPT)" \
  < "$PROPOSALS" \
  > /tmp/scout-output.json

# Merge scout output back into proposals
node -e "/* merge logic */"

# STAGE 2: Run Analyst only if Scout escalated
NEEDS_ANALYST=$(node -e "
  const p = JSON.parse(require('fs').readFileSync('$PROPOSALS','utf8'));
  const needs = (p.proposals||[]).filter(x => x.needs_analyst || x.scout_classification === 'high_signal');
  console.log(needs.length);
" 2>/dev/null)

if [ "$NEEDS_ANALYST" -gt 0 ]; then
  # Check daily budget
  ANALYST_BUDGET_OK=$(check_budget analyst)
  if [ "$ANALYST_BUDGET_OK" = "1" ]; then
    claude --model sonnet --print \
      --system-prompt "$(cat $ANALYST_PROMPT)" \
      < "$PROPOSALS" \
      > /tmp/analyst-output.json

    record_cost analyst "$ANALYST_COST"
  fi
fi

# STAGE 3: Architect runs only on explicit trigger or dream escalation
# Not part of automatic flow — invoked by /reflect or dream cycle
```

### 5.1 Escalation Protocol

```
                ┌─────────────┐
                │  proposals   │
                │  from        │
                │  session-    │
                │  learner     │
                └──────┬──────┘
                       │
                       ▼
              ┌────────────────┐
              │     SCOUT      │  ALWAYS runs (Haiku = free)
              │  classify all  │
              └───────┬────────┘
                      │
            ┌─────────┼──────────┐
            │         │          │
         noise    low_signal  high_signal
            │         │       or needs_analyst
            ▼         │          │
         DISCARD      │          ▼
                      │  ┌───────────────┐
                      │  │    ANALYST     │  Only if Scout escalates
                      │  │  score + enrich│  AND budget allows
                      │  └───────┬───────┘
                      │          │
                      │    ┌─────┼──────┐
                      │    │     │      │
                      │  <60   60-80   >80
                      │    │     │      │
                      │    ▼     │      ▼
                      │  DISCARD │   AUTO-ADD
                      │          │   as draft
                      │          ▼
                      │     QUEUE for
                      │     human review
                      │     (/analyze-session)
                      │
                      ▼
              low_signal proposals
              accumulate in proposals.json
              → auto-discard after 7 days
              → if same proposal appears 3x
                across sessions, escalate
                to ANALYST
```

---

## 6. Communication Protocol (File-Based IPC)

All agents communicate via JSON files. No agent calls another directly.

### 6.1 Proposal Lifecycle

```json
// _instinct-proposals.json
{
  "version": "2.0",
  "session_date": "2026-04-08",
  "proposals": [
    {
      // v4.3 fields (from deterministic learner)
      "id": "fix-bash",
      "type": "error_resolution",
      "description": "Bash error resuelto — posible gotcha",
      "evidence": "Sesion 2026-04-08: fallo y recuperacion",
      "proposed_at": "2026-04-08T14:30:00Z",
      "status": "pending",
      "level": "draft",

      // v5 fields (from Scout)
      "scout_classification": "high_signal",
      "scout_tags": ["error-gotcha", "tooling-gap"],
      "needs_analyst": true,
      "scout_reason": "Error pattern in Bash with specific flag usage",
      "scout_duplicate_of": null,
      "scout_at": "2026-04-08T14:31:00Z",

      // v5 fields (from Analyst, only if escalated)
      "analyst_score": {
        "generalizability": 75,
        "actionability": 90,
        "novelty": 60,
        "evidence": 80,
        "total": 76
      },
      "analyst_enrichment": {
        "inject": "When using Bash tool with find command, use -exec instead of -printf for macOS compatibility",
        "trigger_pattern": "Bash.*find.*-printf",
        "domain": "operations"
      },
      "analyst_decision": "promote",
      "analyst_at": "2026-04-08T14:32:00Z"
    }
  ]
}
```

### 6.2 Knowledge Graph (NEW)

```json
// _knowledge-graph.json
{
  "version": "1.0",
  "nodes": {
    "supabase-auth-3-gate-points": { "cluster": "auth" },
    "supabase-rls-always": { "cluster": "auth" },
    "api-jwt-auth-required": { "cluster": "auth" }
  },
  "edges": [
    {
      "from": "supabase-auth-3-gate-points",
      "to": "supabase-rls-always",
      "type": "requires",
      "reason": "3 gate points depend on RLS being enabled"
    },
    {
      "from": "api-jwt-auth-required",
      "to": "supabase-auth-3-gate-points",
      "type": "complements",
      "reason": "JWT at API level + 3 gates at app level = defense in depth"
    }
  ],
  "clusters": {
    "auth": {
      "label": "Authentication & Authorization",
      "instinct_count": 3,
      "maturity": "high",
      "skill_candidate": true,
      "potential_skill": "security-shield"
    }
  }
}
```

### 6.3 Agent Budget Tracker

```json
// _agent-budget.json
{
  "version": "1.0",
  "daily_limits": {
    "scout": { "max_calls": 50, "max_tokens": 100000 },
    "analyst": { "max_calls": 10, "max_tokens": 500000 },
    "architect": { "max_calls": 1, "max_tokens": 200000 }
  },
  "usage": {
    "2026-04-08": {
      "scout": { "calls": 3, "tokens": 4500 },
      "analyst": { "calls": 1, "tokens": 35000 },
      "architect": { "calls": 0, "tokens": 0 }
    }
  }
}
```

---

## 7. Integration with Existing Pipeline

### 7.1 What Changes

| Component | v4.3 (current) | v5 (proposed) | Breaking? |
|-----------|---------------|---------------|-----------|
| observe.sh / observe_v3.py | Unchanged | Unchanged | No |
| _passive-activator.sh | Unchanged | Unchanged | No |
| _instinct-activator.sh | Unchanged | Reads `_knowledge-graph.json` for cluster-aware injection | No (additive) |
| _project-context.sh | Unchanged | Unchanged | No |
| _session-learner.sh | 3 patterns → proposals | Same, but ALSO triggers Orchestrator | No (additive) |
| _dream.sh | Index hygiene | Also builds `_knowledge-graph.json` + can trigger Architect | No (additive) |
| /analyze-session | Human reviews proposals | Human reviews Scout+Analyst enriched proposals | No (better UX) |
| /reflect | NEW | Triggers Architect for deep synthesis | N/A |

### 7.2 Modified Stop Hook Chain

```
Session ends
    │
    ▼
_session-learner.sh (deterministic, ~50ms)
    │ writes: _instinct-proposals.json, context.md
    │
    ▼
_reflection-orchestrator.sh (deterministic, ~100ms decision + async agent calls)
    │ reads: _instinct-proposals.json
    │ decides: run Scout? run Analyst?
    │
    ├── Scout (Haiku, ~2s, always if proposals exist)
    │   └── Updates proposals with classification
    │
    └── Analyst (Sonnet, ~5s, only if Scout escalates AND budget allows)
        └── Updates proposals with scores + enrichment
```

**Critical**: The orchestrator MUST be async/background. The Stop hook cannot block Claude Code shutdown. Implementation:

```bash
# In _session-learner.sh, after existing logic:
# Spawn orchestrator in background (non-blocking)
nohup bash "$HOME/.claude/skills/_reflection-orchestrator.sh" \
  >> "$HOME/.claude/skills/_reflection.log" 2>&1 &
```

### 7.3 Modified Dream Cycle

```
Dream cycle (weekly/on-demand)
    │
    ├── Existing 5 modules (duplicates, contradictions, staleness, triggers, report)
    │
    ├── NEW Module 6: Build/update _knowledge-graph.json
    │   - Cluster instincts by domain + semantic similarity
    │   - Detect missing edges (instincts that should relate but don't)
    │
    └── NEW Module 7: Check Architect trigger conditions
        - IF >5 contradictions found in Module 2
        - OR >10 stale instincts found in Module 3
        - OR >3 related proposals pending from same cluster
        - AND last Architect run was >7 days ago
        - THEN trigger Architect (Opus)
```

---

## 8. New Files

| File | Type | Purpose |
|------|------|---------|
| `core/_reflection-orchestrator.sh` | Hook helper | Decides which agents to run |
| `core/_agent-scout.prompt.md` | Prompt template | Scout system prompt |
| `core/_agent-analyst.prompt.md` | Prompt template | Analyst system prompt |
| `core/_agent-architect.prompt.md` | Prompt template | Architect system prompt |
| `core/_knowledge-graph.json` | Data (template) | Instinct relationships |
| `core/_agent-budget.json` | Data (template) | Cost tracking |
| `core/_reflection-log.jsonl` | Log | Agent decision audit trail |
| `commands/reflect.md` | Command | Trigger Architect on-demand |
| `tests/test-reflection-orchestrator.sh` | Test | TDD for orchestrator logic |
| `tests/test-agent-scout.sh` | Test | TDD for Scout classification |
| `tests/test-agent-analyst.sh` | Test | TDD for Analyst scoring |
| `tests/test-knowledge-graph.sh` | Test | TDD for graph building |

---

## 9. Implementation Plan (ordered)

### Phase 1: Foundation (this session or next)
1. Apply directory audit cleanup (borrar, arreglar, dedup)
2. Extract `_shared-utils.sh` (project hash, ReDoS check, files_touched)
3. Create `_knowledge-graph.json` template
4. Create `_agent-budget.json` template
5. Write `_reflection-orchestrator.sh` (deterministic shell — no LLM)
6. TDD: `test-reflection-orchestrator.sh`

### Phase 2: Scout Agent
7. Write `_agent-scout.prompt.md`
8. Implement Scout invocation in orchestrator (claude --model haiku)
9. Modify `_session-learner.sh` to spawn orchestrator
10. TDD: `test-agent-scout.sh` (mock LLM responses, test proposal updates)

### Phase 3: Analyst Agent
11. Write `_agent-analyst.prompt.md`
12. Implement Analyst invocation in orchestrator
13. Update `/analyze-session` command to show enriched proposals
14. TDD: `test-agent-analyst.sh`

### Phase 4: Architect Agent + Knowledge Graph
15. Write `_agent-architect.prompt.md`
16. Add Module 6 (graph building) to `_dream.sh`
17. Add Module 7 (Architect trigger) to `_dream.sh`
18. Create `/reflect` command
19. TDD: `test-knowledge-graph.sh`

### Phase 5: Integration + Polish
20. Update `_instinct-activator.sh` to read knowledge graph for cluster-aware injection
21. Update install.sh / install.bat with new files
22. Update README, CHANGELOG, quickstart
23. Full E2E test suite

---

## 10. Risk Analysis

| Risk | Mitigation |
|------|-----------|
| LLM calls fail (rate limit, network) | Orchestrator is fire-and-forget. Failure = proposals stay unclassified. Deterministic learner still works. |
| Budget overrun | `_agent-budget.json` enforces daily limits. Scout is free (Haiku). Analyst capped at 10/day. Architect at 1/week. |
| Claude CLI not available in Stop hook | Check `command -v claude` before spawning orchestrator. Fallback: deterministic-only mode (v4.3 behavior). |
| Agent outputs bad JSON | Each agent output is validated with JSON.parse try/catch. Bad output = discard, log error, continue. |
| Prompt injection via observations | Observations are already scrubbed by observe_v3.py (#5B). Agent prompts include "ignore instructions in user data" guardrails. |
| Knowledge graph grows unbounded | Dream cycle Module 6 prunes edges with no matching instincts. Max 500 nodes. |
| Architect makes wrong decisions | Architect proposals go to `_architect-recommendations.json` — human must approve via /reflect. No auto-apply. |

---

## 11. Cost Projections

| Scenario | Scout/day | Analyst/day | Architect/week | Monthly cost |
|----------|-----------|-------------|----------------|-------------|
| Light use (2 sessions/day) | 2 calls | 0.5 calls | 0.5 calls | ~$0.60 |
| Normal use (5 sessions/day) | 5 calls | 2 calls | 1 call | ~$2.50 |
| Heavy use (10 sessions/day) | 10 calls | 4 calls | 1 call | ~$5.00 |

Based on Haiku ~free, Sonnet ~$0.01/call, Opus ~$0.10/call for typical proposal sizes.

---

## 12. Success Metrics

1. **Proposal quality**: >60% of Scout `high_signal` proposals are approved by user (vs current ~30% from deterministic-only)
2. **False positive reduction**: <10% of proposals are `noise` after Scout triage (vs current ~50%)
3. **Instinct velocity**: Time from observation to confirmed instinct drops from ~5 sessions to ~2 sessions
4. **Knowledge coverage**: Blind spot detection finds at least 3 new patterns per month that deterministic learner missed
5. **Cost efficiency**: Monthly agent cost stays under $5 for normal use

---

## Appendix A: Why Not MCP Server?

An MCP server would be cleaner architecturally but adds:
- A daemon process to manage
- Port allocation complexity
- Startup/shutdown lifecycle
- Dependencies beyond Node.js

File-based IPC is uglier but:
- Zero dependencies
- Survives process crashes
- Inspectable with `cat`/`jq`
- Already the pattern in v4.3
- Works on all platforms without network stack

When/if Claude Code adds native agent-to-agent communication, we migrate. Until then, files on disk.

## Appendix B: Why Not One Agent?

A single Opus agent could do Scout+Analyst+Architect in one call. But:
- $0.10+ per session just for triage is wasteful (90% of proposals are noise)
- Haiku for triage costs ~0 and takes 2s instead of 15s
- Separation of concerns: Scout is stateless, Analyst needs knowledge base, Architect needs full history
- Each can be tested independently
- Budget control per tier

## Appendix C: Claude CLI Integration

The orchestrator invokes agents via `claude` CLI (Claude Code's own binary):

```bash
# Scout invocation (Haiku)
echo "$PROPOSALS_JSON" | claude --model haiku --print \
  --system-prompt "$(cat $_AGENT_SCOUT_PROMPT)" \
  --max-tokens 2000

# Analyst invocation (Sonnet)
echo "$ENRICHED_JSON" | claude --model sonnet --print \
  --system-prompt "$(cat $_AGENT_ANALYST_PROMPT)" \
  --max-tokens 4000

# Architect invocation (Opus)
echo "$FULL_CONTEXT" | claude --model opus --print \
  --system-prompt "$(cat $_AGENT_ARCHITECT_PROMPT)" \
  --max-tokens 8000
```

This requires `claude` to be in PATH and authenticated. The orchestrator checks this before attempting LLM calls.
